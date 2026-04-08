import Foundation

/// Defines the supported text-to-speech providers for Talk Mode.
public enum TalkProvider: String, Sendable, CaseIterable {
    case elevenLabs = "elevenlabs"
    case mistral = "mistral"
    
    /// The environment variable name used for this provider's API key.
    public var apiKeyEnvName: String {
        switch self {
        case .elevenLabs: return "ELEVENLABS_API_KEY"
        case .mistral: return "MISTRAL_API_KEY"
        }
    }
}
