import Foundation

public enum MistralTTSError: Error, LocalizedError {
    case invalidURL
    case requestFailed(status: Int, message: String)
    case missingAudioData
    case decodingFailed(Error)
    
    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid Mistral TTS URL"
        case .requestFailed(let status, let message):
            return "Mistral TTS request failed (Status \(status)): \(message)"
        case .missingAudioData: return "Mistral TTS response missing audio data"
        case .decodingFailed(let error): return "Mistral TTS decoding failed: \(error.localizedDescription)"
        }
    }
}

public struct MistralTTSVoice: Codable, Sendable {
    public let id: String
    public let slug: String?
}

public struct MistralTTSRequest: Codable, Sendable {
    public let text: String
    public let modelId: String
    public let voiceId: String?
    public let speed: Double?
    public let responseFormat: String
    public let stream: Bool?
    
    enum CodingKeys: String, CodingKey {
        case text = "input"
        case modelId = "model"
        case voiceId = "voice"
        case speed
        case responseFormat = "response_format"
        case stream
    }

    public init(text: String, modelId: String, voiceId: String?, speed: Double?, responseFormat: String, stream: Bool? = nil) {
        self.text = text
        self.modelId = modelId
        self.voiceId = voiceId
        self.speed = speed
        self.responseFormat = responseFormat
        self.stream = stream
    }
}

private struct MistralTTSResponse: Codable {
    let audio_data: String?
}

private struct MistralSSEEvent: Codable {
    let event: String
    let data: MistralSSEData
    
    struct MistralSSEData: Codable {
        let audio_data: String?
    }
}

public actor MistralTTSClient {
    public static let baseUrl = "https://api.mistral.ai/v1"
    public static let speechPath = "/audio/speech"
    public static let listVoicesPath = "/tts/voices"
    public static let defaultModelId = "voxtral-mini-tts-2603"
    public static let defaultVoiceId = "1024d823-a11e-43ee-bf3d-d440dccc0577" // Paul - Happy
    public static let defaultOutputFormat = "opus"
    
    private let apiKey: String
    private var voicesTask: Task<[MistralTTSVoice], Error>?

    public init(apiKey: String) {
        self.apiKey = apiKey
    }

    public func clearCache() async {
        self.voicesTask = nil
    }

    public func resolveVoiceId(requested: String, fallback: String? = nil) async throws -> String? {
        let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 1. Fail fast for empty input
        guard !trimmed.isEmpty else { return fallback }        

        // 2. If it's a valid UUID, return it immediately.
        if UUID(uuidString: trimmed) != nil {
            return trimmed
        }
        
        // 3. Fetch (or use cached) voices to resolve slugs and validate
        let allVoices = try await self.voices
        
        // 4. Try to find requested voice by slug or ID
        if let match = allVoices.first(where: { $0.slug == trimmed || $0.id == trimmed }) {
            return match.id
        }
        
        // 5. Try fallback if provided
        if let fallback = fallback?.trimmingCharacters(in: .whitespacesAndNewlines), !fallback.isEmpty {
            if let match = allVoices.first(where: { $0.slug == fallback || $0.id == fallback }) {
                return match.id
            }
        }
        
        // 6. Last resort: pick the first available voice
        return allVoices.first?.id
    }

    public var voices: [MistralTTSVoice] {
        get async throws {
            if let task = voicesTask {
                return try await task.value
            }
            let task = Task {
                try await self.fetchVoicesFromServer()
            }
            self.voicesTask = task
            return try await task.value
        }
    }

    private func fetchVoicesFromServer() async throws -> [MistralTTSVoice] {
        guard var components = URLComponents(string: Self.baseUrl + Self.listVoicesPath) else {
            throw MistralTTSError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "limit", value: "100")]
        
        guard let url = components.url else {
            throw MistralTTSError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(self.apiKey)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw MistralTTSError.requestFailed(status: status, message: errorMsg)
        }
        
        struct MistralTTSVoiceList: Codable {
            let items: [MistralTTSVoice]
        }
        let list = try JSONDecoder().decode(MistralTTSVoiceList.self, from: data)
        return list.items
    }

    /// Returns an asynchronous stream of audio data.
    /// Uses Server-Sent Events (SSE) to stream audio deltas in real-time.
    public func streamSynthesize(request: MistralTTSRequest) -> AsyncThrowingStream<Data, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    guard var url = URL(string: Self.baseUrl + Self.speechPath), url.scheme != nil else {
                        throw MistralTTSError.invalidURL
                    }
                    let maskedKey = self.apiKey.count > 8 ? "\(self.apiKey.prefix(4))...\(self.apiKey.suffix(4))" : "****"
                    print("[MistralTTS] 🔗 url=\(url)")
                    print("[MistralTTS] 🔑 apikey=\(maskedKey)")
                    print("[MistralTTS] 🤖 model=\(request.modelId)")
                    print("[MistralTTS] 🗣️ voice=\(request.voiceId ?? "nil")")
                    print("[MistralTTS] 📦 responseFormat=\(request.responseFormat)")

                    var urlRequest = URLRequest(url: url)
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("Bearer \(self.apiKey)", forHTTPHeaderField: "Authorization")
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    
                    let body = try JSONEncoder().encode(request)
                    urlRequest.httpBody = body
                    
                    if request.stream == true {
                        let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
                        
                        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                            var errorMsg = "Streaming request failed"
                            
                            // Try to read the first bit of the error response
                            var errorData = Data()
                            do {
                                for try await byte in bytes {
                                    errorData.append(byte)
                                    if errorData.count > 1024 { break }
                                }
                                errorMsg = String(data: errorData, encoding: .utf8) ?? errorMsg
                            } catch {
                                errorMsg = "Streaming request failed with error: \(error.localizedDescription)"
                            }
                            
                            print("[MistralTTS] ❌ Error (Status \(status)): \(errorMsg)")
                            print("[MistralTTS] 📝 Request Payload: \(String(data: body, encoding: .utf8) ?? "unable to encode body")")
                            throw MistralTTSError.requestFailed(status: status, message: errorMsg)
                        }
                        
                        var currentEvent: String?
                        for try await line in bytes.lines {
                            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                            if trimmed.isEmpty { continue }
                            
                            if trimmed.hasPrefix("event: ") {
                                currentEvent = String(trimmed.dropFirst(7))
                            } else if trimmed.hasPrefix("data: ") {
                                let dataStr = String(trimmed.dropFirst(6))
                                if dataStr == "[DONE]" {
                                    continuation.finish()
                                    return
                                }
                                
                                guard let eventData = dataStr.data(using: .utf8) else { continue }
                                
                                if currentEvent == "speech.audio.delta" || currentEvent == nil {
                                    // Sometimes data follows event, sometimes it's just data
                                    if let audioEvent = try? JSONDecoder().decode(MistralSSEEvent.MistralSSEData.self, from: eventData),
                                       let base64 = audioEvent.audio_data,
                                       let data = Data(base64Encoded: base64) {
                                        continuation.yield(data)
                                    }
                                } else if currentEvent == "speech.audio.done" {
                                    continuation.finish()
                                    return
                                }
                            }
                        }
                        continuation.finish()
                    } else {
                        // Legacy unary path
                        let (data, response) = try await URLSession.shared.data(for: urlRequest)
                        
                        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                            let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown error"
                            print("[MistralTTS] ❌ Error (Status \(status)): \(errorMsg)")
                            print("[MistralTTS] 📝 Request Payload: \(String(data: body, encoding: .utf8) ?? "unable to encode body")")
                            throw MistralTTSError.requestFailed(status: status, message: errorMsg)
                        }
                        
                        let decoded = try JSONDecoder().decode(MistralTTSResponse.self, from: data)
                        guard let audioBase64 = decoded.audio_data,
                              let audioData = Data(base64Encoded: audioBase64) else {
                            throw MistralTTSError.missingAudioData
                        }
                        
                        continuation.yield(audioData)
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
