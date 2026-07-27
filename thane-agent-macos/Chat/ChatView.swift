import SwiftUI
import SwiftData

struct ChatView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState

    let conversation: Conversation
    let ollamaURL: URL?

    @State private var viewModel: ChatViewModel?
    @State private var inputText = ""

    var body: some View {
        messageList
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Divider()
                inputBar
                    .background(.bar)
            }
        .navigationTitle(conversation.title)
        .navigationSubtitle(appState.statusText)
        .onAppear { resetViewModel() }
        .onChange(of: conversation.id) { resetViewModel() }
        .onChange(of: ollamaURL) { resetViewModel() }
        .onDisappear { cancelViewModel() }
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if conversation.sortedMessages.isEmpty {
                        conversationWelcome
                    }

                    ForEach(conversation.sortedMessages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }

                    if let vm = viewModel, vm.isStreaming {
                        MessageBubble(
                            role: "assistant",
                            content: vm.streamingContent,
                            isStreaming: true
                        )
                        .id("streaming")
                    }

                    if let error = viewModel?.error {
                        errorBanner(error)
                    }
                }
                .frame(maxWidth: 820)
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
            .onChange(of: conversation.sortedMessages.count) {
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: viewModel?.streamingContent) {
                scrollToBottom(proxy: proxy)
            }
        }
    }

    private var conversationWelcome: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
                .frame(width: 54, height: 54)
                .background(.tint.opacity(0.1), in: Circle())

            Text("Start a conversation")
                .font(.title3.weight(.semibold))

            Text("Thane can reason with the context, tools, and Apple capabilities you’ve chosen to share.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)

            if viewModel != nil {
                HStack(spacing: 8) {
                    suggestion("What should I know today?")
                    suggestion("Show me what you can do")
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private func suggestion(_ text: String) -> some View {
        Button(text) {
            inputText = text
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(12)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewModel == nil {
                HStack {
                    Label("Connect to a server before sending a message.", systemImage: "bolt.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    SettingsLink {
                        Text("Connection Settings…")
                    }
                    .controlSize(.small)
                }
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message Thane", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(.separator.opacity(0.5))
                    }

                sendButton
            }
        }
        .frame(maxWidth: 840)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
    }

    private var sendButton: some View {
        Button(action: handleSendButton) {
            Image(systemName: viewModel?.isStreaming == true
                  ? "stop.circle.fill"
                  : "arrow.up.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .keyboardShortcut(.return, modifiers: .command)
        .help(viewModel?.isStreaming == true ? "Stop (⌘↩)" : "Send (⌘↩)")
    }

    private var canSend: Bool {
        guard viewModel != nil else { return false }
        return viewModel?.isStreaming == true
            || !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Actions

    private func handleSendButton() {
        if viewModel?.isStreaming == true {
            viewModel?.cancel()
            return
        }
        sendMessage()
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        viewModel?.send(text, modelContext: modelContext)
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            if viewModel?.isStreaming == true {
                proxy.scrollTo("streaming", anchor: .bottom)
            } else if let last = conversation.sortedMessages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private func resetViewModel() {
        cancelViewModel()
        setupViewModel()
    }

    private func cancelViewModel() {
        viewModel?.cancel()
    }

    private func setupViewModel() {
        guard let url = ollamaURL else {
            viewModel = nil
            return
        }
        let client = OllamaClient(baseURL: url)
        viewModel = ChatViewModel(conversation: conversation, client: client)
    }
}
