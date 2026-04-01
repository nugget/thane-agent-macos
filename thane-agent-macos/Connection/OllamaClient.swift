import Foundation
import os

// MARK: - Ollama API Types

struct OllamaRequest: Encodable {
    let model: String
    let messages: [OllamaMessage]
    let stream: Bool
}

struct OllamaMessage: Codable {
    let role: String
    let content: String
}

struct OllamaStreamChunk: Decodable {
    let model: String
    let message: OllamaMessage?
    let done: Bool
    let doneReason: String?

    enum CodingKeys: String, CodingKey {
        case model, message, done
        case doneReason = "done_reason"
    }
}

// MARK: - Client

struct OllamaClient {
    let baseURL: URL
    var model: String = "thane"

    private let logger = Logger(subsystem: "info.nugget.thane-agent-macos", category: "ollama")

    /// Stream a chat completion. Yields string tokens as they arrive.
    func chat(messages: [OllamaMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let url = baseURL.appending(path: "api/chat")
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.timeoutInterval = 120

                    let body = OllamaRequest(model: model, messages: messages, stream: true)
                    request.httpBody = try JSONEncoder().encode(body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    guard let http = response as? HTTPURLResponse else {
                        throw OllamaError.badResponse(0)
                    }
                    guard http.statusCode == 200 else {
                        throw OllamaError.badResponse(http.statusCode)
                    }

                    for try await line in bytes.lines {
                        guard !line.isEmpty else { continue }
                        guard let data = line.data(using: .utf8) else { continue }

                        let chunk = try JSONDecoder().decode(OllamaStreamChunk.self, from: data)

                        if let content = chunk.message?.content, !content.isEmpty {
                            continuation.yield(content)
                        }

                        if chunk.done {
                            continuation.finish()
                            return
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

// MARK: - Errors

enum OllamaError: LocalizedError {
    case notConfigured
    case badResponse(Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "No server configured. Add a server in Settings."
        case .badResponse(let code):
            "Server returned an unexpected response (HTTP \(code))."
        }
    }
}
