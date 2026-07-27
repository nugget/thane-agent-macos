import AppKit
import SwiftUI

struct MessageBubble: View {
    let role: String
    let content: String
    var isStreaming: Bool = false
    var createdAt: Date?

    @State private var isHovered = false

    init(message: ChatMessage) {
        self.role = message.role
        self.content = message.content
        self.createdAt = message.createdAt
    }

    init(role: String, content: String, isStreaming: Bool = false) {
        self.role = role
        self.content = content
        self.isStreaming = isStreaming
        self.createdAt = nil
    }

    private var isUser: Bool { role == "user" }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if isUser { Spacer(minLength: 60) }

            if !isUser {
                Image(systemName: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 26, height: 26)
                    .background(.tint.opacity(0.1), in: Circle())
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                bubbleContent
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(isUser ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                    .foregroundStyle(isUser ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 13))
                    .contextMenu {
                        Button("Copy", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(content, forType: .string)
                        }
                    }

                if isStreaming {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Thane is thinking…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 4)
                } else if isHovered, let createdAt {
                    Text(createdAt, format: .dateTime.hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .transition(.opacity)
                }
            }

            if !isUser { Spacer(minLength: 60) }
        }
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    @ViewBuilder
    private var bubbleContent: some View {
        if let attributed = try? AttributedString(
            markdown: content,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            Text(attributed)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(content)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
