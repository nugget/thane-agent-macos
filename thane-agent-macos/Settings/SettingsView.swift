import SwiftUI
import SwiftData
import AppKit
import ServiceManagement

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsView()
            }
            Tab("Remote", systemImage: "network") {
                ServerSettingsView()
            }
            Tab("Local", systemImage: "desktopcomputer") {
                LocalServerSettingsView()
            }
        }
        .frame(width: 480)
    }
}

// MARK: - Server Tab

struct ServerSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Query private var configs: [ServerConfig]

    @State private var serverURL = ""
    @State private var token = ""
    @State private var showToken = false

    private var config: ServerConfig? { configs.first(where: \.isDefault) }

    var body: some View {
        Form {
            Section("Connection") {
                TextField("Base URL", text: $serverURL, prompt: Text("http://pocket.local"))
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Group {
                        if showToken {
                            TextField("API Token", text: $token)
                        } else {
                            SecureField("API Token", text: $token)
                        }
                    }
                    .textFieldStyle(.roundedBorder)

                    Button {
                        showToken.toggle()
                    } label: {
                        Image(systemName: showToken ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }
            }

            Section("Status") {
                HStack {
                    Label(appState.statusText,
                          systemImage: appState.isConnected ? "circle.fill" : "circle")
                        .foregroundStyle(appState.isConnected ? .green : .secondary)

                    Spacer()

                    if appState.isConnected {
                        Button("Disconnect") { appState.disconnect() }
                    } else {
                        Button("Connect") {
                            saveConfig()
                            connectToServer()
                        }
                        .disabled(serverURL.isEmpty || token.isEmpty)
                    }
                }

                if let error = appState.connection.lastError {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }

                if let providerID = appState.connection.providerID {
                    LabeledContent("Provider ID", value: providerID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear(perform: loadConfig)
    }

    private func loadConfig() {
        serverURL = config?.urlString ?? ""
        token = config.map { appState.loadToken(for: $0) ?? "" } ?? ""
    }

    private func saveConfig() {
        let cfg: ServerConfig
        if let existing = config {
            existing.urlString = serverURL
            cfg = existing
        } else {
            cfg = ServerConfig(name: "Default", urlString: serverURL)
            modelContext.insert(cfg)
        }
        if !token.isEmpty { appState.saveToken(token, for: cfg) }
        try? modelContext.save()
    }

    private func connectToServer() {
        guard let config else { return }
        appState.connect(config: config)
    }
}

// MARK: - Local Server Tab

struct LocalServerSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    private var manager: BinaryManager { appState.binaryManager }

    var body: some View {
        Form {
            Section("Binary") {
                pathRow(
                    label: "Executable",
                    url: manager.binaryURL,
                    placeholder: "Not found",
                    hint: "Search paths: \(BinaryManager.searchPaths.map(\.lastPathComponent).joined(separator: ", "))",
                    startingDirectory: manager.binaryURL?.deletingLastPathComponent(),
                    canChooseFiles: true,
                    canChooseDirectories: false,
                    onPick: { manager.binaryURL = $0 }
                )
                pathRow(
                    label: "Workspace",
                    url: manager.workspaceURL,
                    placeholder: "~/Thane/",
                    hint: "Working directory — thane finds config.yaml here automatically",
                    startingDirectory: manager.workspaceURL,
                    canChooseFiles: false,
                    canChooseDirectories: true,
                    onPick: { manager.workspaceURL = $0 }
                )
                pathRow(
                    label: "Config",
                    url: manager.configURL,
                    placeholder: "Auto (CWD + thane's discovery order)",
                    hint: "Override only if config.yaml isn't in the workspace",
                    startingDirectory: manager.configURL?.deletingLastPathComponent() ?? manager.workspaceURL,
                    canChooseFiles: true,
                    canChooseDirectories: false,
                    onPick: { manager.configURL = $0 }
                )
            }

            Section("Status") {
                HStack {
                    statusLabel
                    Spacer()
                    controlButtons
                }

                HStack {
                    Spacer()
                    Button("Open Console") {
                        openWindow(id: "console")
                    }
                    .disabled(manager.logLines.isEmpty && !manager.state.isRunning)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var statusLabel: some View {
        Label {
            Text(manager.state.label)
        } icon: {
            Circle()
                .fill(stateColor)
                .frame(width: 8, height: 8)
        }
    }

    private var stateColor: Color {
        switch manager.state {
        case .running:          .green
        case .starting:         .yellow
        case .crashed:          .red
        case .stopped, .notConfigured: .secondary
        }
    }

    @ViewBuilder
    private var controlButtons: some View {
        switch manager.state {
        case .running:
            Button("Stop", role: .destructive) { manager.stop() }
        case .stopped, .crashed:
            Button("Start") { manager.start() }
                .disabled(manager.binaryURL == nil)
        case .starting:
            ProgressView().scaleEffect(0.7)
        case .notConfigured:
            EmptyView()
        }
    }

    @ViewBuilder
    private func pathRow(
        label: String,
        url: URL?,
        placeholder: String,
        hint: String,
        startingDirectory: URL?,
        canChooseFiles: Bool,
        canChooseDirectories: Bool,
        onPick: @escaping (URL) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .frame(width: 70, alignment: .leading)

                Text(url?.path ?? placeholder)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(url != nil ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button("Browse...") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = canChooseFiles
                    panel.canChooseDirectories = canChooseDirectories
                    panel.allowsMultipleSelection = false
                    panel.directoryURL = startingDirectory
                    if panel.runModal() == .OK, let picked = panel.url {
                        onPick(picked)
                    }
                }
            }

            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - General Tab

struct GeneralSettingsView: View {
    @State private var loginItemStatus = SMAppService.mainApp.status

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { loginItemStatus == .enabled },
            set: { enable in
                do {
                    if enable {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    loginItemStatus = SMAppService.mainApp.status
                } catch {
                    loginItemStatus = SMAppService.mainApp.status
                }
            }
        )
    }

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: launchAtLoginBinding)
                if loginItemStatus == .requiresApproval {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.yellow)
                        Text("Approval required in System Settings → General → Login Items.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Open…") {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { loginItemStatus = SMAppService.mainApp.status }
    }
}
