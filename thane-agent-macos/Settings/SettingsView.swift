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
            Tab("Permissions", systemImage: "lock.shield") {
                PermissionsSettingsView()
            }
        }
        .frame(width: 520)
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
        if !token.isEmpty {
            appState.saveToken(token, for: cfg)
        } else {
            appState.deleteToken(for: cfg)
        }
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
                    Button("Process Health") {
                        openWindow(id: "process-health")
                    }
                    .disabled(!manager.state.isRunning && manager.state != .stopped)
                }
            }

            Section("Updates") {
                UpdateSettingsSection()
            }

            Section("Code Signature") {
                CodeSignatureSection()
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

// MARK: - Permissions Tab

struct PermissionsSettingsView: View {
    @Environment(AppState.self) private var appState

    private var manager: PermissionsManager { appState.permissionsManager }

    var body: some View {
        Form {
            Section {
                calendarRow
            } header: {
                Text("Private Data")
            } footer: {
                Text("Calendar access powers the macOS calendar tool exposed back to a connected Thane server.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Full Disk Access — requires manual action in System Settings
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text("Full Disk Access")
                            .font(.headline)
                    }
                    Text("Grants thane unrestricted read access to all files, including areas outside your home folder. Must be approved manually in System Settings — it cannot be requested via a dialog.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Open System Settings…") {
                            NSWorkspace.shared.open(
                                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
                            )
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            // Per-category rows
            Section {
                ForEach(manager.categories) { category in
                    categoryRow(category)
                }
            } header: {
                Text("File Locations")
            } footer: {
                Text("These locations are accessed by the thane process. Request access upfront to avoid unexpected permission dialogs during unattended server operation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Custom locations
            Section {
                HStack {
                    Spacer()
                    Button("Add Location…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.allowsMultipleSelection = false
                        panel.message = "Choose a directory for thane to access"
                        if panel.runModal() == .OK, let url = panel.url {
                            manager.addCustomLocation(url)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            Task {
                await appState.refreshCalendarAuthorization()
                await manager.refreshPreviouslyRequested()
            }
        }
    }

    private var calendarRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Calendars")
                Text("EventKit access for upcoming meetings and scheduling context.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                calendarStatusBadge(appState.calendarAuthorization)
                calendarActionButton(appState.calendarAuthorization)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func categoryRow(_ category: PermissionsManager.Category) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(category.name)
                Text(category.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                statusBadge(category.status)
                HStack(spacing: 6) {
                    if category.isCustom {
                        Button("Remove") {
                            manager.removeCustomLocation(categoryID: category.id)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .foregroundStyle(.red)
                    }
                    actionButton(category)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func statusBadge(_ status: PermissionsManager.Status) -> some View {
        switch status {
        case .notRequested:
            Text("Not Requested")
                .font(.caption)
                .foregroundStyle(.tertiary)
        case .granted:
            Label("Granted", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .denied:
            Label("Denied", systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func actionButton(_ category: PermissionsManager.Category) -> some View {
        switch category.status {
        case .notRequested:
            Button("Request Access") {
                Task { await manager.requestAccess(categoryID: category.id) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        case .granted:
            Button("Re-check") {
                Task { await manager.requestAccess(categoryID: category.id) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        case .denied:
            Button("Open Settings…") {
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func calendarStatusBadge(_ status: CalendarAuthorizationState) -> some View {
        switch status {
        case .notDetermined:
            Text("Not Requested")
                .font(.caption)
                .foregroundStyle(.tertiary)
        case .fullAccess:
            Label("Granted", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .denied, .restricted, .writeOnly, .unknown:
            Label(status.label, systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func calendarActionButton(_ status: CalendarAuthorizationState) -> some View {
        switch status {
        case .notDetermined:
            Button("Request Access") {
                Task { await appState.requestCalendarAccess() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        case .fullAccess, .unknown:
            Button("Re-check") {
                Task { await appState.refreshCalendarAuthorization() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        case .denied, .restricted, .writeOnly:
            Button("Open Settings…") {
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
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
