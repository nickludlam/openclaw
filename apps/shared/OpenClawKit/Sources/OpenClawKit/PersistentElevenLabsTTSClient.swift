import Foundation
import ElevenLabsKit

/// A persistent wrapper around `ElevenLabsTTSClient` that handles voice resolution and fallback caching.
public actor PersistentElevenLabsTTSClient {
    public static let defaultModelId = "eleven_v3"

    private let apiKey: String
    private let client: ElevenLabsTTSClient
    private var cachedFallbackVoiceId: String?

    public init(apiKey: String) {
        self.apiKey = apiKey
        self.client = ElevenLabsTTSClient(apiKey: apiKey)
    }

    public func clearCache() {
        self.cachedFallbackVoiceId = nil
    }

    /// Resolves a requested voice string to a final ID.
    /// - Parameters:
    ///   - requested: The desired voice string (ID, slug, or nil).
    ///   - fallback: A default ID to use if resolution fails.
    /// - Returns: A resolved voice ID, or nil if no fallback is available.
    public func resolveVoiceId(requested: String?, fallback: String? = nil) async -> String? {
        let trimmed = requested?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            // UUID always takes precedence
            if UUID(uuidString: trimmed) != nil {
                return trimmed
            }
            // ElevenLabs specific ID check (alphanumeric strings like '21m0AOTTVbmS4p09fdxF')
            if Self.isLikelyVoiceId(trimmed) {
                return trimmed
            }
        }

        // If we have a cached fallback, use it.
        if let cached = cachedFallbackVoiceId {
            return cached
        }

        // Otherwise, list voices to find a fallback.
        do {
            let voices = try await client.listVoices()
            guard let first = voices.first else {
                return fallback
            }
            self.cachedFallbackVoiceId = first.voiceId
            return first.voiceId
        } catch {
            return fallback
        }
    }

    /// Checks if a string looks like an ElevenLabs voice ID.
    public static func isLikelyVoiceId(_ value: String) -> Bool {
        guard value.count >= 10 else { return false }
        return value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// Passthrough to `ElevenLabsTTSClient.streamSynthesize`.
    public func streamSynthesize(voiceId: String, request: ElevenLabsTTSRequest) -> AsyncThrowingStream<Data, Error> {
        client.streamSynthesize(voiceId: voiceId, request: request)
    }
}
