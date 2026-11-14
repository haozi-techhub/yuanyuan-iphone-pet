import Foundation

nonisolated struct DeepSeekClient {
    static let defaultModel = "deepseek-flash"

    struct Message: Codable, Sendable {
        let role: String
        let content: String
    }

    struct Reply: Codable, Sendable {
        struct Command: Codable, Sendable {
            let type: String
            let value: String?
        }

        let reply: String
        let emotion: String?
        let command: Command?

        private enum CodingKeys: String, CodingKey {
            case reply, emotion, command
        }

        init(reply: String, emotion: String? = nil, command: Command? = nil) {
            self.reply = reply
            self.emotion = emotion
            self.command = command
        }

        var historyMessage: Message {
            // Keep prior assistant turns in the same JSON format requested for new turns.
            let encoded = (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) }
            return Message(role: "assistant", content: encoded ?? "{}")
        }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            reply = try fields.decode(String.self, forKey: .reply)
            emotion = try? fields.decode(String.self, forKey: .emotion)
            command = try? fields.decode(Command.self, forKey: .command)
        }
    }

    enum RequestError: Error {
        case invalidResponse
        case httpStatus(Int)
    }

    private struct Request: Encodable {
        struct Option: Encodable { let type: String }

        let model: String
        let messages: [Message]
        let responseFormat: Option?
        let thinking = Option(type: "disabled")
        let maxTokens = 300

        enum CodingKeys: String, CodingKey {
            case model, messages, thinking
            case responseFormat = "response_format"
            case maxTokens = "max_tokens"
        }
    }

    private struct Completion: Decodable {
        struct Choice: Decodable {
            struct Output: Decodable { let content: String? }
            let message: Output
        }

        let choices: [Choice]
    }

    private static let endpoint = URL(string: "https://api.deepseek.com/chat/completions")!
    private static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }()

    private let session: URLSession

    init(session: URLSession? = nil) {
        self.session = session ?? Self.defaultSession
    }

    func reply(apiKey: String, model: String, messages: [Message]) async throws -> Reply {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let modelName = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = modelName.isEmpty ? Self.defaultModel : modelName
        request.httpBody = try JSONEncoder().encode(
            Request(model: model, messages: messages, responseFormat: .init(type: "json_object"))
        )

        do {
            return try await send(request, structured: true)
        } catch RequestError.invalidResponse {
            try Task.checkCancellation()
            let plainMessages = messages.map { message in
                if message.role == "system" {
                    return Message(role: "system", content: "你是可爱的桌宠。用简体中文接着上下文说一句话，不超过 40 字。只回复纯文本，不输出 JSON 或设备指令。")
                }
                if message.role == "assistant",
                   let previous = try? JSONDecoder().decode(Reply.self, from: Data(message.content.utf8)) {
                    return Message(role: "assistant", content: previous.reply)
                }
                return message
            }
            request.httpBody = try JSONEncoder().encode(
                Request(model: model, messages: plainMessages, responseFormat: nil)
            )
            return try await send(request, structured: false)
        }
    }

    private func send(_ request: URLRequest, structured: Bool) async throws -> Reply {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RequestError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw RequestError.httpStatus(http.statusCode)
        }
        let decoder = JSONDecoder()
        guard let completion = try? decoder.decode(Completion.self, from: data),
              let content = completion.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty
        else { throw RequestError.invalidResponse }
        if let reply = try? decoder.decode(Reply.self, from: Data(content.utf8)),
           !reply.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return structured ? reply : Reply(reply: reply.reply)
        }
        guard !structured, !content.hasPrefix("{"), !content.hasPrefix("["), !content.hasPrefix("```") else {
            throw RequestError.invalidResponse
        }
        return Reply(reply: content)
    }
}
