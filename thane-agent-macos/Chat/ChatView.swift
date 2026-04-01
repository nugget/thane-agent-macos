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
        VStack(spacing: 0) {
            messageList
            Divider()
            inputBar
        }
        .navigationTitle(conversation.title)
        .navigationSubtitle(appState.statusText)
        .onAppear { setupViewModel() }
        .onChange(of: conversation.id) { setupViewModel() }
        .onChange(of: ollamaURL) { setupViewModel() }
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
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
                .padding()
            }
            .onChange(of: conversation.sortedMessages.count) {
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: viewModel?.streamingContent) {
                scrollToBottom(proxy: proxy)
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle")
            Text(message)
                .font(.callout)
        }
        .foregroundStyle(.red)
        .padding(.horizontal)
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.background.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            sendButton
        }
        .padding()
    }

    private var sendButton: some View {
        Button(action: handleSendButton) {
            Image(systemName: viewModel?.isStreaming == true
                  ? "stop.circle.fill"
                  : "arrow.up.circle.fill")
                .font(.title2)
                .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .keyboardShortcut(.return, modifiers: .command)
        .help(viewModel?.isStreaming == true ? "Stop (⌘↩)" : "Send (⌘↩)")
    }

    private var canSend: Bool {
        viewModel?.isStreaming == true || !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    private func setupViewModel() {
        guard let url = ollamaURL else {
            viewModel = nil
            return
        }
        let client = OllamaClient(baseURL: url)
        viewModel = ChatViewModel(conversation: conversation, client: client)
    }
}
