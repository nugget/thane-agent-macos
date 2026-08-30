import SwiftData
import SwiftUI

struct MainView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @Query(filter: #Predicate<ServerConfig> { $0.isDefault }) private var defaultConfigs: [ServerConfig]

    @State private var selectedConversation: Conversation?

    private var ollamaURL: URL? {
        if appState.configurationMode == .managed,
           appState.binaryManager.state.isRunning {
            let port = appState.binaryManager.localConfig.ollamaPort
            return URL(string: "http://localhost:\(port)")
        }
        return defaultConfigs.first?.ollamaURL
    }

    var body: some View {
        NavigationSplitView {
            ConversationListView(selection: $selectedConversation)
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 340)
        } detail: {
            if let conversation = selectedConversation {
                ChatView(conversation: conversation, ollamaURL: ollamaURL)
            } else {
                welcomeView
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .safeAreaInset(edge: .top, spacing: 0) {
            if appState.identityManager.pinState.hasChanged {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundStyle(.red)
                    Text("Thane’s identity or founding history changed.")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Button("Review…") {
                        openWindow(id: "identity")
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.red.opacity(0.1))
                .overlay(alignment: .bottom) { Divider() }
            }
        }
        .onAppear {
            migrateLegacyConfigurationIfNeeded()
            appState.openMainWindow = { openWindow(id: "main") }
            appState.registerProcessHealthWindowOpener {
                openWindow(id: "process-health")
            }
            appState.openDashboardWindow = { openWindow(id: "dashboard") }
            // The unit-test bundle is injected into the application process.
            // Do not activate the operator's persisted server in that host:
            // it would read the real Keychain before any test can begin.
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
                appState.activateSelectedConfiguration(advancedConfig: defaultConfigs.first)
            }
        }
    }

    private var welcomeView: some View {
        VStack(spacing: 18) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 42))
                .foregroundStyle(.tint)
                .frame(width: 82, height: 82)
                .background(.tint.opacity(0.1), in: Circle())

            VStack(spacing: 6) {
                Text("Chat with Thane")
                    .font(.largeTitle.weight(.semibold))
                Text(welcomeDetail)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if appState.isConnected {
                Button("New Conversation", systemImage: "square.and.pencil") {
                    NotificationCenter.default.post(name: .newConversation, object: nil)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                HStack(spacing: 10) {
                    Button("Thane Settings…", systemImage: "gearshape") {
                        appState.selectedSettingsTab = .agent
                        showSettings()
                    }
                    .buttonStyle(.borderedProminent)

                    if appState.managedRuntimeIsRelevant {
                        Button("Agent Health…", systemImage: "waveform.path.ecg") {
                            openWindow(id: "process-health")
                        }
                    }
                }
            }
        }
        .frame(maxWidth: 520)
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var welcomeDetail: String {
        if appState.isConnected {
            return "Choose a conversation, or begin a new one."
        }
        if appState.configurationMode == .managed,
           case .needsAttention = appState.binaryManager.state {
            return "Thane needs attention before you can continue."
        }
        return "Thane is unavailable. Review its settings to get connected."
    }

    private func showSettings() {
        NSApp.activate()
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    private func migrateLegacyConfigurationIfNeeded() {
        guard !appState.hadStoredConfigurationMode,
              appState.binaryManager.state == .notConfigured,
              !defaultConfigs.isEmpty
        else { return }
        appState.selectConfiguration(.advanced, advancedConfig: defaultConfigs.first)
    }
}

extension Notification.Name {
    static let newConversation = Notification.Name("newConversation")
}
