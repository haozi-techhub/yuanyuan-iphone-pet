import Foundation

nonisolated struct DeepSeekClient {
    static let defaultModel = "deepseek-flash"

    struct Message: Codable, Sendable {
        let role: String
        let content: String
    }

    struct Reply: Decodable, Sendable {
        struct Command: Decodable, Sendable {
            let type: String
            let value: String?
        }

        let reply: String
        let emotion: String?
        let command: Command?
    }

    enum RequestError: Error {
        case invalidResponse
        case httpStatus(Int)
    }

    private struct Request: Encodable {
        struct Option: Encodable { let type: String }

        let model: String
        let messages: [Message]
        let responseFormat = Option(type: "json_object")
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
        request.httpBody = try JSONEncoder().encode(
            Request(model: modelName.isEmpty ? Self.defaultModel : modelName, messages: messages)
        )

        do {
            return try await send(request)
        } catch RequestError.invalidResponse {
            try Task.checkCancellation()
            return try await send(request)
        }
    }

    private func send(_ request: URLRequest) async throws -> Reply {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RequestError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw RequestError.httpStatus(http.statusCode)
        }
        let decoder = JSONDecoder()
        guard let completion = try? decoder.decode(Completion.self, from: data),
              let content = completion.choices.first?.message.content,
              let reply = try? decoder.decode(Reply.self, from: Data(content.utf8)),
              !reply.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw RequestError.invalidResponse
        }
        return reply
    }
}
