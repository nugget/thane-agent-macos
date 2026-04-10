import SwiftUI
import SwiftData

struct MainView: View {
    @Environment(AppState.self) private var appState
    @Query(filter: #Predicate<ServerConfig> { $0.isDefault }) private var defaultConfigs: [ServerConfig]

    @State private var selectedConversation: Conversation?

    private var ollamaURL: URL? {
        if let remote = defaultConfigs.first?.ollamaURL { return remote }
        if appState.binaryManager.state.isRunning {
            let port = appState.binaryManager.localConfig.ollamaPort
            return URL(string: "http://localhost:\(port)")
        }
        return nil
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
        .onAppear {
            // Register openWindow with AppState so AppKit contexts (dock menu, etc.) can use it.
            appState.openConsoleWindow = { openWindow(id: "process-health") }
            appState.openDashboardWindow = { openWindow(id: "dashboard") }
            appState.openAboutWindow = { openWindow(id: "about") }
            // Auto-reconnect to the default remote server if one is configured and
            // we aren't already connected (e.g. local binary didn't beat us to it).
            if let config = defaultConfigs.first, !appState.isConnected {
                appState.connect(config: config)
            }
        }
    }

    @Environment(\.openWindow) private var openWindow

    private var emptyState: some View {
        VStack(spacing: 16) {
            if ollamaURL == nil {
                ContentUnavailableView {
                    Label("No Server Configured", systemImage: "server.rack")
                } description: {
                    Text("Connect to a remote server or start a local binary.")
                } actions: {
                    SettingsLink(label: { Text("Open Settings") })
                        .buttonStyle(.borderedProminent)
                }
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
