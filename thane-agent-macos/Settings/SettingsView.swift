import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Server", systemImage: "network") {
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
    @State private var isPickingBinary = false
    @State private var isPickingWorkspace = false
    @State private var isPickingConfig = false

    private var manager: BinaryManager { appState.binaryManager }

    var body: some View {
        Form {
            Section("Binary") {
                pathRow(
                    label: "Executable",
                    url: manager.binaryURL,
                    placeholder: "Not found",
                    hint: "Search paths: \(BinaryManager.searchPaths.map(\.lastPathComponent).joined(separator: ", "))",
                    isPicking: $isPickingBinary,
                    contentTypes: [.unixExecutable],
                    onPick: { manager.binaryURL = $0 }
                )
                pathRow(
                    label: "Workspace",
                    url: manager.workspaceURL,
                    placeholder: "~/Thane/",
                    hint: "Working directory — thane finds config.yaml here automatically",
                    isPicking: $isPickingWorkspace,
                    contentTypes: [.folder],
                    onPick: { manager.workspaceURL = $0 }
                )
                pathRow(
                    label: "Config",
                    url: manager.configURL,
                    placeholder: "Auto (CWD + thane's discovery order)",
                    hint: "Override only if config.yaml isn't in the workspace",
                    isPicking: $isPickingConfig,
                    contentTypes: [.yaml, .data],
                    onPick: { manager.configURL = $0 }
                )
            }

            Section("Status") {
                HStack {
                    statusLabel

                    Spacer()

                    controlButtons
                }
            }

            if !manager.logLines.isEmpty {
                Section("Output") {
                    BinaryLogView(logLines: manager.logLines)
                        .frame(minHeight: 120, maxHeight: 240)
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
        isPicking: Binding<Bool>,
        contentTypes: [UTType],
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

                Button("Browse...") { isPicking.wrappedValue = true }
                    .fileImporter(
                        isPresented: isPicking,
                        allowedContentTypes: contentTypes,
                        onCompletion: { result in
                            guard case .success(let picked) = result else { return }
                            let accessed = picked.startAccessingSecurityScopedResource()
                            defer { if accessed { picked.stopAccessingSecurityScopedResource() } }
                            onPick(URL(fileURLWithPath: picked.path))
                        }
                    )
            }

            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
