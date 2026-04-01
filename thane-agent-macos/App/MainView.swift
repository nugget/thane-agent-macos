import SwiftUI
import SwiftData

struct MainView: View {
    @Environment(AppState.self) private var appState
    @Query(filter: #Predicate<ServerConfig> { $0.isDefault }) private var defaultConfigs: [ServerConfig]

    @State private var selectedConversation: Conversation?

    private var ollamaURL: URL? {
        defaultConfigs.first?.ollamaURL
    }

    var body: some View {
        NavigationSplitView {
            ConversationListView(selection: $selectedConversation)
        } detail: {
            if let conversation = selectedConversation {
                ChatView(conversation: conversation, ollamaURL: ollamaURL)
            } else {
                emptyState
            }
        }
        .frame(minWidth: 700, minHeight: 500)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            if ollamaURL == nil {
                ContentUnavailableView(
                    "No Server Configured",
                    systemImage: "server.rack",
                    description: Text("Add a server in [Settings](settings:) to get started.")
                )
            } else {
                ContentUnavailableView {
                    Label("No Conversation Selected", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Select a conversation or create a new one.")
                } actions: {
                    newConversationButton
                }
            }
        }
    }

    private var newConversationButton: some View {
        Button("New Conversation") {
            // Trigger via notification so ConversationListView handles it
            NotificationCenter.default.post(name: .newConversation, object: nil)
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut("n", modifiers: .command)
    }
}

extension Notification.Name {
    static let newConversation = Notification.Name("newConversation")
}
