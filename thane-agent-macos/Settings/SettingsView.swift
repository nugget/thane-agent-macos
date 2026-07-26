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

    /// Warns when the entered URL would be blocked by App Transport Security:
    /// plaintext http:// to a non-local host. Remote servers must use https://.
    private var insecureRemoteWarning: String? {
        guard let host = ServerConfig.insecurePlaintextHost(in: serverURL) else { return nil }
        return "macOS blocks plaintext HTTP to remote hosts (App Transport Security). Use https:// to reach \(host)."
    }

    var body: some View {
        Form {
            Section("Connection") {
                TextField("Base URL", text: $serverURL, prompt: Text("https://pocket.hollowoak.net"))
                    .textFieldStyle(.roundedBorder)

                if let warning = insecureRemoteWarning {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

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
                        Button("Save & Reconnect") {
                            saveConfig()
                            connectToServer()
                        }
                        .disabled(serverURL.isEmpty || token.isEmpty)
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
        let trimmedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let cfg: ServerConfig
        if let existing = config {
            existing.urlString = trimmedURL
            cfg = existing
        } else {
            cfg = ServerConfig(name: "Default", urlString: trimmedURL)
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
                    hint: "Thane instance — config is read from core/config.yaml here",
                    startingDirectory: manager.workspaceURL,
                    canChooseFiles: false,
                    canChooseDirectories: true,
                    onPick: { manager.workspaceURL = $0 }
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

            Section("Binary Updates") {
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
        case .refused:          .orange
        case .stopped, .notConfigured: .secondary
        }
    }

    @ViewBuilder
    private var controlButtons: some View {
        switch manager.state {
        case .running:
            Button("Stop", role: .destructive) { manager.stop() }
        case .stopped, .crashed, .refused:
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
                remindersRow
                contactsRow
            } header: {
                Text("Private Data")
            } footer: {
                Text("These grants power the macOS platform tools exposed back to a connected Thane server.")
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
                await appState.refreshContactsAuthorization()
                await appState.refreshRemindersAuthorization()
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
                eventKitStatusBadge(appState.calendarAuthorization)
                eventKitActionButton(
                    appState.calendarAuthorization,
                    privacyPane: "Privacy_Calendars",
                    onRequest: { await appState.requestCalendarAccess() },
                    onRecheck: { await appState.refreshCalendarAuthorization() }
                )
            }
        }
        .padding(.vertical, 4)
    }

    private var remindersRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Reminders")
                Text("EventKit access for to-dos, due dates, and task lists.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                eventKitStatusBadge(appState.remindersAuthorization)
                eventKitActionButton(
                    appState.remindersAuthorization,
                    privacyPane: "Privacy_Reminders",
                    onRequest: { await appState.requestRemindersAccess() },
                    onRecheck: { await appState.refreshRemindersAuthorization() }
                )
            }
        }
        .padding(.vertical, 4)
    }

    private var contactsRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Contacts")
                Text("Contacts framework access for looking up people, phone numbers, and email addresses.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                contactsStatusBadge(appState.contactsAuthorization)
                contactsActionButton(appState.contactsAuthorization)
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
    private func eventKitStatusBadge(_ status: EventKitAuthorizationState) -> some View {
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
    private func eventKitActionButton(
        _ status: EventKitAuthorizationState,
        privacyPane: String,
        onRequest: @escaping () async -> Void,
        onRecheck: @escaping () async -> Void
    ) -> some View {
        switch status {
        case .notDetermined:
            Button("Request Access") {
                Task { await onRequest() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        case .fullAccess, .unknown:
            Button("Re-check") {
                Task { await onRecheck() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        case .denied, .restricted, .writeOnly:
            Button("Open Settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(privacyPane)") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func contactsStatusBadge(_ status: ContactsAuthorizationState) -> some View {
        switch status {
        case .notDetermined:
            Text("Not Requested")
                .font(.caption)
                .foregroundStyle(.tertiary)
        case .fullAccess:
            Label("Granted", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .limited:
            Label("Limited", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.green)
        case .denied, .restricted, .unknown:
            Label(status.label, systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func contactsActionButton(_ status: ContactsAuthorizationState) -> some View {
        switch status {
        case .notDetermined:
            Button("Request Access") {
                Task { await appState.requestContactsAccess() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        case .fullAccess, .limited, .unknown:
            Button("Re-check") {
                Task { await appState.refreshContactsAuthorization() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        case .denied, .restricted:
            Button("Open Settings…") {
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts")!
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

            Section("Application Updates") {
                AppUpdateSettingsSection()
            }
        }
        .formStyle(.grouped)
        .onAppear { loginItemStatus = SMAppService.mainApp.status }
    }
}
