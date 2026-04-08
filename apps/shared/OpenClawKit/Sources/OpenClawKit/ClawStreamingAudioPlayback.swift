import AudioToolbox
import Foundation
import OSLog
import ElevenLabsKit

final class ClawStreamingAudioPlayback: @unchecked Sendable {
    private static let bufferCount: Int = 3
    private static let bufferSize: Int = 32 * 1024

    private let logger: Logger
    private let lock = NSLock()
    private let scheduleParseWork: (@escaping @Sendable () -> Void) -> Void
    fileprivate let bufferLock = NSLock()
    fileprivate let bufferSemaphore = DispatchSemaphore(value: bufferCount)

    private var continuation: CheckedContinuation<StreamingPlaybackResult, Never>?
    private var finished = false
    private var tearingDown = false
    private var bufferWaits = 0

    private var audioFileStream: AudioFileStreamID?
    private var audioQueue: AudioQueueRef?
    fileprivate var audioFormat: AudioStreamBasicDescription?
    fileprivate var maxPacketSize: UInt32 = 0

    fileprivate var availableBuffers: [AudioQueueBufferRef] = []
    private var currentBuffer: AudioQueueBufferRef?
    private var currentBufferSize: Int = 0
    private var currentPacketDescs: [AudioStreamPacketDescription] = []

    fileprivate var inputFinished = false
    private var startRequested = false

    private var sampleRate: Double = 0

    init(logger: Logger) {
        self.logger = logger
        let parseQueue = DispatchQueue(label: "talk.stream.parse")
        self.scheduleParseWork = { work in parseQueue.async(execute: work) }
    }

    func setContinuation(_ continuation: CheckedContinuation<StreamingPlaybackResult, Never>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func start() {
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        // Use 0 as the hint to enable auto-detection of format (MP3, Opus, AAC, etc.)
        let status = AudioFileStreamOpen(
            selfPtr,
            clawPropertyListenerProc,
            clawPacketsProc,
            AudioFileTypeID(0), 
            &audioFileStream
        )
        if status != noErr {
            logger.error("talk stream open failed: \(status)")
            finish(StreamingPlaybackResult(finished: false, interruptedAt: nil))
        }
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        scheduleParseWork { [weak self] in
            guard let self else { return }
            guard let audioFileStream else { return }
            let status = data.withUnsafeBytes { bytes -> OSStatus in
                AudioFileStreamParseBytes(
                    audioFileStream,
                    UInt32(bytes.count),
                    bytes.baseAddress,
                    []
                )
            }
            if status != noErr {
                logger.error("talk stream parse failed: \(status)")
                fail(NSError(domain: "StreamingAudio", code: Int(status)))
            }
        }
    }

    func finishInput() {
        scheduleParseWork { [weak self] in
            guard let self else { return }
            inputFinished = true
            if audioQueue == nil {
                finish(StreamingPlaybackResult(finished: false, interruptedAt: nil))
                return
            }
            enqueueCurrentBuffer(flushOnly: true)
            _ = stop(immediate: false)
        }
    }

    func fail(_ error: Error) {
        logger.error("talk stream failed: \(error.localizedDescription, privacy: .public)")
        _ = stop(immediate: true)
        finish(StreamingPlaybackResult(finished: false, interruptedAt: nil))
    }

    func stop(immediate: Bool) -> Double? {
        guard let audioQueue else { return nil }
        let interruptedAt = currentTimeSeconds()
        _ = AudioQueueStop(audioQueue, immediate)
        return interruptedAt
    }

    func finish(_ result: StreamingPlaybackResult) {
        let continuation: CheckedContinuation<StreamingPlaybackResult, Never>?
        lock.lock()
        if finished {
            continuation = nil
        } else {
            finished = true
            tearingDown = true
            continuation = self.continuation
            self.continuation = nil
        }
        lock.unlock()

        continuation?.resume(returning: result)
        teardown()
    }

    private func teardown() {
        releaseBufferWaiters()
        if let audioQueue {
            _ = AudioQueueDispose(audioQueue, true)
            self.audioQueue = nil
        }
        if let audioFileStream {
            _ = AudioFileStreamClose(audioFileStream)
            self.audioFileStream = nil
        }
        bufferLock.lock()
        availableBuffers.removeAll()
        bufferLock.unlock()
        currentBuffer = nil
        currentPacketDescs.removeAll()
    }

    private func releaseBufferWaiters() {
        let waits = drainBufferWaits()
        guard waits > 0 else { return }
        for _ in 0..<waits {
            bufferSemaphore.signal()
        }
    }

    private func recordBufferWait() {
        lock.lock()
        bufferWaits += 1
        lock.unlock()
    }

    private func drainBufferWaits() -> Int {
        lock.lock()
        let waits = bufferWaits
        bufferWaits = 0
        lock.unlock()
        return waits
    }

    private func isTearingDown() -> Bool {
        lock.lock()
        let value = tearingDown
        lock.unlock()
        return value
    }

    func setupQueueIfNeeded(_ asbd: AudioStreamBasicDescription) {
        guard audioQueue == nil else { return }

        var format = asbd
        audioFormat = format
        sampleRate = format.mSampleRate

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = AudioQueueNewOutput(
            &format,
            clawOutputCallbackProc,
            selfPtr,
            nil,
            nil,
            0,
            &audioQueue
        )
        if status != noErr {
            logger.error("talk queue create failed: \(status)")
            finish(StreamingPlaybackResult(finished: false, interruptedAt: nil))
            return
        }

        if let audioQueue {
            _ = AudioQueueAddPropertyListener(audioQueue, kAudioQueueProperty_IsRunning, clawIsRunningCallbackProc, selfPtr)
        }

        if let audioFileStream {
            var cookieSize: UInt32 = 0
            var writable: DarwinBoolean = false
            let cookieStatus = AudioFileStreamGetPropertyInfo(
                audioFileStream,
                kAudioFileStreamProperty_MagicCookieData,
                &cookieSize,
                &writable
            )
            if cookieStatus == noErr, cookieSize > 0, let audioQueue {
                var cookie = [UInt8](repeating: 0, count: Int(cookieSize))
                let readStatus = cookie.withUnsafeMutableBytes { bytes -> OSStatus in
                    guard let base = bytes.baseAddress else { return -1 }
                    return AudioFileStreamGetProperty(
                        audioFileStream,
                        kAudioFileStreamProperty_MagicCookieData,
                        &cookieSize,
                        base
                    )
                }
                if readStatus == noErr {
                    _ = AudioQueueSetProperty(audioQueue, kAudioQueueProperty_MagicCookie, cookie, cookieSize)
                }
            }
        }

        if let audioQueue {
            for _ in 0..<Self.bufferCount {
                var buffer: AudioQueueBufferRef?
                let allocStatus = AudioQueueAllocateBuffer(audioQueue, UInt32(Self.bufferSize), &buffer)
                if allocStatus == noErr, let buffer {
                    bufferLock.lock()
                    availableBuffers.append(buffer)
                    bufferLock.unlock()
                }
            }
        }
    }

    fileprivate func enqueueCurrentBuffer(flushOnly: Bool = false) {
        guard !isTearingDown() else { return }
        guard let audioQueue, let buffer = currentBuffer else { return }
        guard currentBufferSize > 0 else { return }

        buffer.pointee.mAudioDataByteSize = UInt32(currentBufferSize)
        let packetCount = UInt32(currentPacketDescs.count)

        let status = currentPacketDescs.withUnsafeBufferPointer { descPtr in
            AudioQueueEnqueueBuffer(audioQueue, buffer, packetCount, descPtr.baseAddress)
        }
        if status != noErr {
            logger.error("talk queue enqueue failed: \(status)")
        } else {
            if !startRequested {
                startRequested = true
                let startStatus = AudioQueueStart(audioQueue, nil)
                if startStatus != noErr {
                    logger.error("talk queue start failed: \(startStatus)")
                }
            }
        }

        currentBuffer = nil
        currentBufferSize = 0
        currentPacketDescs.removeAll(keepingCapacity: true)
        if !flushOnly {
            guard !isTearingDown() else { return }
            bufferLock.lock()
            var next = availableBuffers.popLast()
            bufferLock.unlock()
            if next == nil {
                guard !isTearingDown() else { return }
                recordBufferWait()
                bufferSemaphore.wait()
                guard !isTearingDown() else { return }
                bufferLock.lock()
                next = availableBuffers.popLast()
                bufferLock.unlock()
            }
            if let next { currentBuffer = next }
        }
    }

    func handlePackets(
        numberBytes: UInt32,
        numberPackets: UInt32,
        inputData: UnsafeRawPointer,
        packetDescriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?
    ) {
        if isTearingDown() {
            return
        }
        if audioQueue == nil, let format = audioFormat {
            setupQueueIfNeeded(format)
        }

        if audioQueue == nil {
            return
        }

        if currentBuffer == nil {
            bufferLock.lock()
            currentBuffer = availableBuffers.popLast()
            bufferLock.unlock()
            if currentBuffer == nil {
                guard !isTearingDown() else { return }
                recordBufferWait()
                bufferSemaphore.wait()
                guard !isTearingDown() else { return }
                bufferLock.lock()
                currentBuffer = availableBuffers.popLast()
                bufferLock.unlock()
            }
            currentBufferSize = 0
            currentPacketDescs.removeAll(keepingCapacity: true)
        }

        let bytes = inputData.assumingMemoryBound(to: UInt8.self)
        let packetCount = Int(numberPackets)
        for index in 0..<packetCount {
            let packetOffset: Int
            let packetSize: Int

            if let packetDescriptions {
                packetOffset = Int(packetDescriptions[index].mStartOffset)
                packetSize = Int(packetDescriptions[index].mDataByteSize)
            } else {
                let size = Int(numberBytes) / packetCount
                packetOffset = index * size
                packetSize = size
            }

            if packetSize > Self.bufferSize {
                continue
            }

            if currentBufferSize + packetSize > Self.bufferSize {
                enqueueCurrentBuffer()
            }

            guard let buffer = currentBuffer else { continue }
            let dest = buffer.pointee.mAudioData.advanced(by: currentBufferSize)
            memcpy(dest, bytes.advanced(by: packetOffset), packetSize)

            let desc = AudioStreamPacketDescription(
                mStartOffset: Int64(currentBufferSize),
                mVariableFramesInPacket: 0,
                mDataByteSize: UInt32(packetSize)
            )
            currentPacketDescs.append(desc)
            currentBufferSize += packetSize
        }
    }

    private func currentTimeSeconds() -> Double? {
        guard let audioQueue, sampleRate > 0 else { return nil }
        var timeStamp = AudioTimeStamp()
        let status = AudioQueueGetCurrentTime(audioQueue, nil, &timeStamp, nil)
        if status != noErr { return nil }
        if timeStamp.mSampleTime.isNaN { return nil }
        return timeStamp.mSampleTime / sampleRate
    }
}

private func clawPropertyListenerProc(
    inClientData: UnsafeMutableRawPointer,
    inAudioFileStream: AudioFileStreamID,
    inPropertyID: AudioFileStreamPropertyID,
    ioFlags _: UnsafeMutablePointer<AudioFileStreamPropertyFlags>
) {
    let playback = Unmanaged<ClawStreamingAudioPlayback>.fromOpaque(inClientData).takeUnretainedValue()

    if inPropertyID == kAudioFileStreamProperty_DataFormat {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioFileStreamGetProperty(inAudioFileStream, inPropertyID, &size, &format)
        if status == noErr {
            playback.audioFormat = format
            playback.setupQueueIfNeeded(format)
        }
    } else if inPropertyID == kAudioFileStreamProperty_PacketSizeUpperBound {
        var maxPacketSize: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioFileStreamGetProperty(inAudioFileStream, inPropertyID, &size, &maxPacketSize)
        if status == noErr {
            playback.maxPacketSize = maxPacketSize
        }
    }
}

private func clawPacketsProc(
    inClientData: UnsafeMutableRawPointer,
    inNumberBytes: UInt32,
    inNumberPackets: UInt32,
    inInputData: UnsafeRawPointer,
    inPacketDescriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?
) {
    let playback = Unmanaged<ClawStreamingAudioPlayback>.fromOpaque(inClientData).takeUnretainedValue()
    playback.handlePackets(
        numberBytes: inNumberBytes,
        numberPackets: inNumberPackets,
        inputData: inInputData,
        packetDescriptions: inPacketDescriptions
    )
}

private func clawOutputCallbackProc(
    inUserData: UnsafeMutableRawPointer?,
    inAQ _: AudioQueueRef,
    inBuffer: AudioQueueBufferRef
) {
    guard let inUserData else { return }
    let playback = Unmanaged<ClawStreamingAudioPlayback>.fromOpaque(inUserData).takeUnretainedValue()
    playback.bufferLock.lock()
    playback.availableBuffers.append(inBuffer)
    playback.bufferLock.unlock()
    playback.bufferSemaphore.signal()
}

private func clawIsRunningCallbackProc(
    inUserData: UnsafeMutableRawPointer?,
    inAQ: AudioQueueRef,
    inID: AudioQueuePropertyID
) {
    guard let inUserData else { return }
    guard inID == kAudioQueueProperty_IsRunning else { return }

    let playback = Unmanaged<ClawStreamingAudioPlayback>.fromOpaque(inUserData).takeUnretainedValue()
    var running: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioQueueGetProperty(inAQ, kAudioQueueProperty_IsRunning, &running, &size)
    if status != noErr { return }

    if running == 0, playback.inputFinished {
        playback.finish(StreamingPlaybackResult(finished: true, interruptedAt: nil))
    }
}
