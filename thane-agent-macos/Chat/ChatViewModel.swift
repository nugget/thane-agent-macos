import Foundation
import SwiftData
import os

@Observable
@MainActor
final class ChatViewModel {
    var conversation: Conversation
    var isStreaming = false
    var streamingContent = ""
    var error: String?

    private let client: OllamaClient
    private var streamingTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "info.nugget.thane-agent-macos", category: "chat")

    init(conversation: Conversation, client: OllamaClient) {
        self.conversation = conversation
        self.client = client
    }

    func send(_ text: String, modelContext: ModelContext) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }

        // Persist user message
        let userMessage = ChatMessage(role: "user", content: trimmed)
        userMessage.conversation = conversation
        modelContext.insert(userMessage)
        conversation.messages.append(userMessage)

        // Auto-title from first user message
        if conversation.title == "New Conversation" {
            conversation.title = String(trimmed.prefix(60))
        }
        conversation.updatedAt = Date()

        // Build history for Ollama — send the full conversation
        let history = conversation.sortedMessages.map {
            OllamaMessage(role: $0.role, content: $0.content)
        }

        isStreaming = true
        streamingContent = ""
        error = nil

        streamingTask = Task {
            do {
                for try await token in client.chat(messages: history) {
                    streamingContent += token
                }

                // Commit completed response
                let reply = ChatMessage(role: "assistant", content: streamingContent)
                reply.conversation = conversation
                modelContext.insert(reply)
                conversation.messages.append(reply)
                conversation.updatedAt = Date()
                try? modelContext.save()

                streamingContent = ""
                isStreaming = false
            } catch {
                logger.error("Chat error: \(error.localizedDescription)")
                self.error = error.localizedDescription
                isStreaming = false
                streamingContent = ""
            }
        }
    }

    func cancel() {
        streamingTask?.cancel()
        streamingTask = nil
        isStreaming = false
        streamingContent = ""
    }
}
