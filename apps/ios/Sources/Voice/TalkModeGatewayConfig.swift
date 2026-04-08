import Foundation
import OpenClawKit

struct TalkModeGatewayConfigState {
    let activeProvider: TalkProvider
    let normalizedPayload: Bool
    let missingResolvedPayload: Bool
    let defaultVoiceId: String?
    let voiceAliases: [String: String]
    let defaultModelId: String
    let defaultOutputFormat: String?
    let rawConfigApiKey: String?
    let interruptOnSpeech: Bool?
    let silenceTimeoutMs: Int
}

enum TalkModeGatewayConfigParser {
    static func parse(
        config: [String: Any],
        defaultProvider: TalkProvider,
        defaultSilenceTimeoutMs: Int
    ) -> TalkModeGatewayConfigState {
        let talk = TalkConfigParsing.bridgeFoundationDictionary(config["talk"] as? [String: Any])
        let selection = TalkConfigParsing.selectProviderConfig(
            talk,
            defaultProvider: defaultProvider.rawValue,
            allowLegacyFallback: false)
        let activeProvider = TalkProvider(rawValue: selection?.provider ?? defaultProvider.rawValue) ?? .elevenLabs
        let activeConfig = selection?.config
        let defaultVoiceId = (activeConfig?["voiceId"]?.stringValue ?? activeConfig?["voice"]?.stringValue)?
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let voiceAliases: [String: String]
        if let aliases = activeConfig?["voiceAliases"]?.dictionaryValue {
            var resolved: [String: String] = [:]
            for (key, value) in aliases {
                guard let id = value.stringValue else { continue }
                let normalizedKey = key.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).lowercased()
                let trimmedId = id.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                guard !normalizedKey.isEmpty, !trimmedId.isEmpty else { continue }
                resolved[normalizedKey] = trimmedId
            }
            voiceAliases = resolved
        } else {
            voiceAliases = [:]
        }
        let model = activeConfig?["modelId"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultModelId = (model?.isEmpty == false) ? model! : PersistentElevenLabsTTSClient.defaultModelId
        let defaultOutputFormat = activeConfig?["outputFormat"]?.stringValue?
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let rawConfigApiKey = activeConfig?["apiKey"]?.stringValue?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let interruptOnSpeech = talk?["interruptOnSpeech"]?.boolValue
        let silenceTimeoutMs = TalkConfigParsing.resolvedSilenceTimeoutMs(
            talk,
            fallback: defaultSilenceTimeoutMs)

        return TalkModeGatewayConfigState(
            activeProvider: activeProvider,
            normalizedPayload: selection?.normalizedPayload == true,
            missingResolvedPayload: talk != nil && selection == nil,
            defaultVoiceId: defaultVoiceId,
            voiceAliases: voiceAliases,
            defaultModelId: defaultModelId,
            defaultOutputFormat: defaultOutputFormat,
            rawConfigApiKey: rawConfigApiKey,
            interruptOnSpeech: interruptOnSpeech,
            silenceTimeoutMs: silenceTimeoutMs)
    }
}
