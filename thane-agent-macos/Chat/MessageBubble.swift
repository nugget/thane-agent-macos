import SwiftUI

struct MessageBubble: View {
    let role: String
    let content: String
    var isStreaming: Bool = false

    init(message: ChatMessage) {
        self.role = message.role
        self.content = message.content
    }

    init(role: String, content: String, isStreaming: Bool = false) {
        self.role = role
        self.content = content
        self.isStreaming = isStreaming
    }

    private var isUser: Bool { role == "user" }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser { Spacer(minLength: 60) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                bubbleContent
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(isUser ? Color.accentColor : Color(.controlBackgroundColor))
                    .foregroundStyle(isUser ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                if isStreaming {
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { i in
                            Circle()
                                .fill(.secondary)
                                .frame(width: 5, height: 5)
                                .opacity(isStreaming ? 1 : 0)
                        }
                    }
                    .padding(.leading, 4)
                }
            }

            if !isUser { Spacer(minLength: 60) }
        }
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
