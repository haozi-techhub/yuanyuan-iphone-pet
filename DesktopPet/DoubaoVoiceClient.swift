import Foundation

nonisolated struct DoubaoVoiceClient {
    static let speaker = "zh_female_tuanzi_uranus_bigtts"
    static let sampleRate = 16_000
    static let playbackSampleRate = 24_000

    enum VoiceError: Error {
        case invalidResponse
        case serviceCode(Int)
    }

    struct RecognitionUpdate: Sendable {
        let text: String?
        let isFinal: Bool
        let isSentenceEnd: Bool
    }

    private struct RecognitionBody: Decodable {
        struct Result: Decodable {
            struct Utterance: Decodable {
                let definite: Bool?
            }
            let text: String?
            let utterances: [Utterance]?
        }
        let result: Result?
    }

    private struct AudioChunk: Decodable {
        let code: Int
        let data: String?
    }

    private static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration)
    }()

    var session: URLSession = Self.defaultSession

    func testRecognition(key: String) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                // A short PCM silence sample checks access without opening the microphone.
                let audio = AsyncStream<Data> { stream in
                    stream.yield(Data(count: Self.sampleRate * 2 / 5))
                    stream.finish()
                }
                try await recognize(key: key, audio: audio) { _ in }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    func recognize(key: String, audio: AsyncStream<Data>,
                   onUpdate: @escaping @Sendable (RecognitionUpdate) async -> Void) async throws {
        let url = URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!
        var request = makeRequest(url: url, key: key, resource: "volc.seedasr.sauc.duration")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Connect-Id")
        request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")
        let socket = session.webSocketTask(with: request)
        defer { socket.cancel(with: .goingAway, reason: nil) }
        socket.resume()

        let options: [String: Any] = [
            "audio": ["format": "pcm", "codec": "raw", "rate": Self.sampleRate, "bits": 16, "channel": 1],
            "request": ["model_name": "bigmodel", "enable_itn": true, "enable_punc": true,
                        "result_type": "full", "show_utterances": true, "enable_nonstream": true, "end_window_size": 550]
        ]
        let payload = try JSONSerialization.data(withJSONObject: options)
        try await withTaskCancellationHandler {
            try await socket.send(.data(Self.frame(type: 0x10, serialization: 0x10, payload: payload)))
            try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask {
                    let packetSize = Self.sampleRate * 2 / 5
                    var pending = Data()
                    for await buffer in audio {
                        try Task.checkCancellation()
                        pending.append(buffer)
                        while pending.count > packetSize {
                            try await socket.send(.data(Self.frame(type: 0x20, serialization: 0,
                                                                   payload: Data(pending.prefix(packetSize)))))
                            pending.removeFirst(packetSize)
                        }
                    }
                    try Task.checkCancellation()
                    let last = pending.isEmpty ? Data(count: 320) : pending
                    try await socket.send(.data(Self.frame(type: 0x22, serialization: 0, payload: last)))
                    return false
                }
                group.addTask {
                    while !Task.isCancelled {
                        guard case let .data(packet) = try await socket.receive() else {
                            throw VoiceError.invalidResponse
                        }
                        let update = try Self.decodeRecognition(packet)
                        await onUpdate(update)
                        if update.isFinal { return true }
                    }
                    throw CancellationError()
                }
                do {
                    while let isFinal = try await group.next() {
                        if isFinal { break }
                    }
                } catch {
                    socket.cancel(with: .goingAway, reason: nil)
                    group.cancelAll()
                    throw error
                }
                socket.cancel(with: .goingAway, reason: nil)
                group.cancelAll()
            }
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    func synthesize(text: String, key: String) async throws -> Data {
        try await synthesize(text: text, key: key, format: "wav", speechRate: 0)
    }

    func streamSpeech(text: String, key: String, onAudio: @escaping @Sendable (Data) async throws -> Void) async throws {
        _ = try await synthesize(text: text, key: key, format: "pcm", speechRate: 15, onAudio: onAudio)
    }

    private func synthesize(text: String, key: String, format: String, speechRate: Int,
                            onAudio: (@Sendable (Data) async throws -> Void)? = nil) async throws -> Data {
        let url = URL(string: "https://openspeech.bytedance.com/api/v3/tts/unidirectional/sse")!
        var request = makeRequest(url: url, key: key, resource: "seed-tts-2.0")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "req_params": ["text": text, "speaker": Self.speaker,
                           "audio_params": ["format": format, "sample_rate": Self.playbackSampleRate, "speech_rate": speechRate]]
        ])
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw VoiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw VoiceError.serviceCode(http.statusCode) }
        var audio = Data()
        var receivedAudio = false
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let chunk = try Self.decodeAudio(line.dropFirst(5))
            if let data = chunk.data {
                receivedAudio = true
                if let onAudio { try await onAudio(data) } else { audio.append(data) }
            }
            if chunk.finished {
                guard receivedAudio else { throw VoiceError.invalidResponse }
                return audio
            }
        }
        throw VoiceError.invalidResponse
    }

    private func makeRequest(url: URL, key: String, resource: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "X-Api-Key")
        request.setValue(resource, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
        return request
    }

    private static func decodeAudio(_ payload: Substring) throws -> (data: Data?, finished: Bool) {
        let chunk = try JSONDecoder().decode(AudioChunk.self, from: Data(payload.utf8))
        guard chunk.code == 0 || chunk.code == 20_000_000 else {
            throw VoiceError.serviceCode(chunk.code)
        }
        var decoded: Data?
        if let data = chunk.data, !data.isEmpty {
            guard let audio = Data(base64Encoded: data) else { throw VoiceError.invalidResponse }
            decoded = audio
        }
        return (decoded, chunk.code == 20_000_000)
    }

    static func frame(type: UInt8, serialization: UInt8, payload: Data) -> Data {
        var packet = Data([0x11, type, serialization, 0])
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { packet.append(contentsOf: $0) }
        packet.append(payload)
        return packet
    }

    static func decodeRecognition(_ packet: Data) throws -> RecognitionUpdate {
        guard packet.count >= 8 else { throw VoiceError.invalidResponse }
        let start = packet.startIndex
        let headerSize = Int(packet[start] & 0x0f) * 4
        let type = packet[start + 1] >> 4
        let flags = packet[start + 1] & 0x0f
        guard packet[start] >> 4 == 1, headerSize >= 4, headerSize <= packet.count - 4 else {
            throw VoiceError.invalidResponse
        }
        func integer(at offset: Int) -> Int {
            packet[(start + offset)..<(start + offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
        }
        if type == 0x0f { throw VoiceError.serviceCode(integer(at: headerSize)) }
        let sizeOffset = headerSize + (flags & 1 == 1 ? 4 : 0)
        guard type == 9, packet[start + 2] == 0x10, sizeOffset <= packet.count - 4 else {
            throw VoiceError.invalidResponse
        }
        let size = integer(at: sizeOffset)
        let payloadStart = sizeOffset + 4
        guard size == packet.count - payloadStart else { throw VoiceError.invalidResponse }
        let result = try JSONDecoder().decode(RecognitionBody.self,
                                              from: packet[(start + payloadStart)..<packet.endIndex])
        return RecognitionUpdate(text: result.result?.text, isFinal: flags & 2 != 0,
                                 isSentenceEnd: result.result?.utterances?.last?.definite == true)
    }
}
