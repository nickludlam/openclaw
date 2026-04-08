import Foundation
import OSLog
import ElevenLabsKit

/// Plays streaming audio chunks using the shared AVAudioSession-backed player.
/// This version is format-agnostic and will auto-detect Opus, MP3, etc.
@MainActor
public final class ClawStreamingAudioPlayer: NSObject, StreamingAudioPlaying {
    /// Shared player instance.
    public static let shared = ClawStreamingAudioPlayer()

    private let logger = Logger(subsystem: "ai.openclaw", category: "talk.tts.stream")
    private var playback: ClawStreamingAudioPlayback?

    /// Starts playing a streaming audio payload.
    public func play(stream: AsyncThrowingStream<Data, Error>) async -> StreamingPlaybackResult {
        stopInternal()

        let playback = ClawStreamingAudioPlayback(logger: logger)
        self.playback = playback

        return await withCheckedContinuation { continuation in
            playback.setContinuation(continuation)
            playback.start()

            Task.detached {
                do {
                    for try await chunk in stream {
                        playback.append(chunk)
                    }
                    playback.finishInput()
                } catch {
                    playback.fail(error)
                }
            }
        }
    }

    /// Stops playback immediately and returns the interrupted timestamp.
    public func stop() -> Double? {
        guard let playback else { return nil }
        let interruptedAt = playback.stop(immediate: true)
        finish(playback: playback, result: StreamingPlaybackResult(finished: false, interruptedAt: interruptedAt))
        return interruptedAt
    }

    private func stopInternal() {
        guard let playback else { return }
        let interruptedAt = playback.stop(immediate: true)
        finish(playback: playback, result: StreamingPlaybackResult(finished: false, interruptedAt: interruptedAt))
    }

    private func finish(playback: ClawStreamingAudioPlayback, result: StreamingPlaybackResult) {
        playback.finish(result)
        guard self.playback === playback else { return }
        self.playback = nil
    }
}
