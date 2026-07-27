import SwiftData
import SwiftUI

struct MainView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @Query(filter: #Predicate<ServerConfig> { $0.isDefault }) private var defaultConfigs: [ServerConfig]

    @State private var selectedConversation: Conversation?

    private var ollamaURL: URL? {
        if appState.binaryManager.state.isRunning {
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
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    openWindow(id: "server")
                } label: {
                    Label("Server", systemImage: "server.rack")
                }
                .help("Server Status (⌘1)")
                .disabled(appState.activeServer == nil)

                Button {
                    openWindow(id: "dashboard")
                } label: {
                    Label("Dashboard", systemImage: "rectangle.3.group")
                }
                .help("Web Dashboard (⌘2)")
                .disabled(appState.dashboardURL == nil)

                Button {
                    openWindow(id: "process-health")
                } label: {
                    Label("Local Thane", systemImage: localStatusIcon)
                }
                .help("Local Thane (⌘3)")
            }
        }
        .onAppear {
            appState.openMainWindow = { openWindow(id: "main") }
            appState.openConsoleWindow = { openWindow(id: "process-health") }
            appState.openDashboardWindow = { openWindow(id: "dashboard") }
            appState.openServerWindow = { openWindow(id: "server") }
            connectRemoteIfAppropriate()
        }
        .onChange(of: appState.binaryManager.state) {
            connectRemoteIfAppropriate()
        }
    }

    private var welcomeView: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 10) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .frame(width: 82, height: 82)
                        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)

                    Text("Thane")
                        .font(.largeTitle.weight(.semibold))
                    Text("Your agent, at home on this Mac.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                statusCard

                if case .needsAttention = appState.binaryManager.state {
                    attentionCard
                } else if ollamaURL == nil {
                    setupCard
                } else {
                    readyActions
                }
            }
            .frame(maxWidth: 620)
            .padding(.horizontal, 32)
            .padding(.vertical, 48)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var statusCard: some View {
        HStack(spacing: 12) {
            Image(systemName: appState.isConnected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(appState.isConnected ? .green : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(appState.statusText)
                    .font(.headline)
                Text(activeServerDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !appState.isConnected {
                SettingsLink {
                    Text("Connection Settings…")
                }
                .controlSize(.small)
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var attentionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Local Thane needs attention", systemImage: "exclamationmark.shield.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            Text(appState.binaryManager.lastValidationReport?.operatorSummary
                 ?? "The signed core did not pass startup verification. Automatic restart is paused.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Button("Review Findings", systemImage: "list.bullet.clipboard") {
                    openWindow(id: "process-health")
                }
                .buttonStyle(.borderedProminent)

                SettingsLink {
                    Text("Local Settings…")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.orange.opacity(0.25))
        }
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose where Thane lives")
                .font(.headline)
            Text("Run a signed instance on this Mac, or connect to one you already operate.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                SettingsLink {
                    Label("Set Up This Mac", systemImage: "desktopcomputer")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                SettingsLink {
                    Label("Connect to a Server", systemImage: "network")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var readyActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What would you like to do?")
                .font(.headline)

            HStack(spacing: 12) {
                actionButton("New Conversation", icon: "square.and.pencil") {
                    NotificationCenter.default.post(name: .newConversation, object: nil)
                }

                actionButton("Server Status", icon: "server.rack") {
                    openWindow(id: "server")
                }

                if appState.binaryManager.state != .notConfigured {
                    actionButton("Local Thane", icon: "waveform.path.ecg") {
                        openWindow(id: "process-health")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actionButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .padding(14)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
    }

    private var activeServerDetail: String {
        if appState.activeServer?.isLocal == true {
            return "Using the signed instance on this Mac"
        }
        if let server = appState.activeServer {
            return server.baseURL.host ?? server.baseURL.absoluteString
        }
        if appState.binaryManager.state == .starting {
            return "Verifying the local signed core"
        }
        return "No active server"
    }

    private var localStatusIcon: String {
        switch appState.binaryManager.state {
        case .running: "checkmark.circle.fill"
        case .starting: "checkmark.shield"
        case .needsAttention: "exclamationmark.shield.fill"
        case .crashed: "exclamationmark.triangle.fill"
        case .stopped: "stop.circle"
        case .notConfigured: "questionmark.circle"
        }
    }

    private func connectRemoteIfAppropriate() {
        guard !appState.isConnected, let config = defaultConfigs.first else { return }
        switch appState.binaryManager.state {
        case .starting, .running:
            return
        case .notConfigured, .stopped, .crashed, .needsAttention:
            appState.connect(config: config)
        }
    }
}

extension Notification.Name {
    static let newConversation = Notification.Name("newConversation")
}
