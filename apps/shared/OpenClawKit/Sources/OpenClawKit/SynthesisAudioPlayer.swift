import Foundation
import ElevenLabsKit

/// Encapsulates the dual-player logic for synthesis playback, handling PCM/MP3 switching 
/// and tracking interruption timestamps across both engines.
@MainActor
public final class SynthesisAudioPlayer {
    private let pcmPlayer: PCMStreamingAudioPlaying
    private let mp3Player: StreamingAudioPlaying
    
    /// Sticky state: set to true if the provider rejects PCM (e.g. subscription restricted).
    private(set) public var pcmFormatUnavailable: Bool = false
    
    /// Tracks which player was last active so that `stop()` can return the correct timestamp.
    private(set) public var lastPlaybackWasPCM: Bool = false
    
    public init(pcmPlayer: PCMStreamingAudioPlaying, mp3Player: StreamingAudioPlaying) {
        self.pcmPlayer = pcmPlayer
        self.mp3Player = mp3Player
    }
    
    /// Plays raw PCM audio data. Automatically updates `lastPlaybackWasPCM`.
    public func playPCM(stream: AsyncThrowingStream<Data, Error>, sampleRate: Double) async -> StreamingPlaybackResult {
        self.lastPlaybackWasPCM = true
        return await pcmPlayer.play(stream: stream, sampleRate: sampleRate)
    }
    
    /// Plays encoded MP3 audio data. Automatically updates `lastPlaybackWasPCM`.
    public func playMP3(stream: AsyncThrowingStream<Data, Error>) async -> StreamingPlaybackResult {
        self.lastPlaybackWasPCM = false
        return await mp3Player.play(stream: stream)
    }
    
    /// Stops any active playback and returns the timestamp from the active player.
    /// Also stops the secondary player to ensure a clean state.
    public func stop() -> Double? {
        let interruptedAt = self.lastPlaybackWasPCM ? pcmPlayer.stop() : mp3Player.stop()
        
        // Stop the other player as well to ensure the audio engine is clean
        _ = self.lastPlaybackWasPCM ? mp3Player.stop() : pcmPlayer.stop()
        
        return interruptedAt
    }
    
    /// Marks PCM as unavailable for the rest of the session.
    public func setPCMFormatUnavailable(_ unavailable: Bool) {
        self.pcmFormatUnavailable = unavailable
    }
    
    /// Resets the sticky fallback state and stops all internal players.
    public func reset() {
        self.pcmFormatUnavailable = false
        _ = pcmPlayer.stop()
        _ = mp3Player.stop()
    }
}
