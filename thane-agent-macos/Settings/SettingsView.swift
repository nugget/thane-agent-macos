import SwiftUI
import SwiftData
import AppKit
import ServiceManagement

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        TabView(selection: $appState.selectedSettingsTab) {
            Tab("General", systemImage: "gearshape", value: .general) {
                GeneralSettingsView()
            }
            Tab("Remote", systemImage: "network", value: .remote) {
                ServerSettingsView()
            }
            Tab("Local", systemImage: "desktopcomputer", value: .local) {
                LocalServerSettingsView()
            }
            Tab("Permissions", systemImage: "lock.shield", value: .permissions) {
                PermissionsSettingsView()
            }
        }
        .frame(width: 620)
        .frame(minHeight: 520)
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
    private var notificationManager: LocalThaneNotificationManager {
        appState.localNotificationManager
    }

    var body: some View {
        Form {
            Section("Status") {
                HStack(spacing: 12) {
                    Image(systemName: statusIcon)
                        .font(.title3)
                        .foregroundStyle(stateColor)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(manager.state.label)
                            .font(.headline)
                        Text(statusDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                    controlButtons
                }

                HStack {
                    Button("Process Health…", systemImage: "waveform.path.ecg") {
                        openWindow(id: "process-health")
                    }
                    .disabled(manager.state == .notConfigured)

                    Spacer()

                    Button("Reveal Workspace", systemImage: "folder") {
                        NSWorkspace.shared.open(manager.workspaceURL)
                    }
                }
                .controlSize(.small)
            }

            if case .needsAttention = manager.state {
                Section {
                    Label {
                        Text(manager.lastValidationReport?.operatorSummary
                             ?? "Thane cannot start until the signed core is repaired.")
                    } icon: {
                        Image(systemName: "exclamationmark.shield.fill")
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Operator Attention")
                } footer: {
                    Text("Automatic restart is paused for terminal exit 78. Process Health shows the exact findings and repair commands.")
                }
            }

            Section {
                pathRow(
                    label: "Executable",
                    url: manager.binaryURL,
                    placeholder: "Not found",
                    hint: "A signed Thane release managed by this app, or a development binary you select.",
                    startingDirectory: manager.binaryURL?.deletingLastPathComponent(),
                    canChooseFiles: true,
                    canChooseDirectories: false,
                    onPick: { manager.binaryURL = $0 }
                )
                pathRow(
                    label: "Workspace",
                    url: manager.workspaceURL,
                    placeholder: "~/Thane/",
                    hint: "The instance root. Thane’s signed core, databases, archives, and generated state live here.",
                    startingDirectory: manager.workspaceURL,
                    canChooseFiles: false,
                    canChooseDirectories: true,
                    onPick: { manager.workspaceURL = $0 }
                )

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Signed Config")
                            .frame(width: 90, alignment: .leading)
                        Text(manager.canonicalConfigURL.path)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer()
                        Button("Reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting([manager.canonicalConfigURL])
                        }
                        .controlSize(.small)
                    }
                    Text("Always loaded from core/config.yaml and verified against signed history before launch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 90)
                }
            } header: {
                Text("Managed Instance")
            } footer: {
                Text("Loading an arbitrary config bypasses Thane’s trust boundary, so recovery mode remains an explicit command-line operation rather than a persistent app preference.")
            }

            Section("Binary Updates") {
                UpdateSettingsSection()
            }

            notificationSettingsSection

            Section("Code Signature") {
                CodeSignatureSection()
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            Task {
                await notificationManager.refreshAuthorization()
            }
        }
    }

    private var notificationSettingsSection: some View {
        Section {
            notificationToggle(
                title: "Errors",
                detail: "Active notifications that are not automatically expired.",
                isOn: Binding(
                    get: { notificationManager.preferences.notifyOnErrors },
                    set: { notificationManager.setErrorsEnabled($0) }
                )
            )

            notificationToggle(
                title: "Warnings",
                detail: "Quiet notifications for lower-urgency events, with configurable retention.",
                isOn: Binding(
                    get: { notificationManager.preferences.notifyOnWarnings },
                    set: { notificationManager.setWarningsEnabled($0) }
                )
            )

            if notificationManager.preferences.isEnabled {
                LabeledContent("Permission") {
                    HStack(spacing: 8) {
                        notificationAuthorizationBadge
                        if notificationManager.authorization != .notRequested {
                            Button("System Settings…") {
                                notificationManager.openSystemNotificationSettings()
                            }
                            .controlSize(.small)
                        }
                    }
                }

                notificationToggle(
                    title: "Play a sound for errors",
                    detail: "Uses the standard alert sound when macOS permits notification sounds.",
                    isOn: Binding(
                        get: { notificationManager.preferences.playSoundForErrors },
                        set: { notificationManager.setErrorSoundEnabled($0) }
                    )
                )
                .disabled(!notificationManager.preferences.notifyOnErrors)

                notificationToggle(
                    title: "Include the log message",
                    detail: "More useful at a glance, but may expose paths or operational details in previews.",
                    isOn: Binding(
                        get: { notificationManager.preferences.includeLogDetails },
                        set: { notificationManager.setIncludeLogDetails($0) }
                    )
                )

                notificationToggle(
                    title: "Notify while Thane is active",
                    detail: "Normally the in-app activity view is updated without interrupting you.",
                    isOn: Binding(
                        get: { notificationManager.preferences.notifyWhileAppIsActive },
                        set: { notificationManager.setNotifyWhileActive($0) }
                    )
                )

                if notificationManager.preferences.notifyOnErrors,
                   notificationManager.preferences.playSoundForErrors,
                   notificationManager.authorization == .allowed,
                   !notificationManager.systemSoundsEnabled {
                    Text("Notification sounds are currently disabled in System Settings.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Picker(
                    "Repeat identical events",
                    selection: Binding(
                        get: { notificationManager.preferences.repeatInterval },
                        set: { notificationManager.setRepeatInterval($0) }
                    )
                ) {
                    ForEach(LocalNotificationRepeatInterval.allCases) { interval in
                        Text(interval.title).tag(interval)
                    }
                }

                if notificationManager.preferences.notifyOnWarnings {
                    Picker(
                        "Keep warnings",
                        selection: Binding(
                            get: { notificationManager.preferences.warningLifetime },
                            set: { notificationManager.setWarningLifetime($0) }
                        )
                    ) {
                        ForEach(WarningNotificationLifetime.allCases) { lifetime in
                            Text(lifetime.title).tag(lifetime)
                        }
                    }
                }

                if let muteUntil = notificationManager.muteUntil {
                    HStack {
                        Label {
                            Text("Muted until \(muteUntil, format: .dateTime.hour().minute())")
                        } icon: {
                            Image(systemName: "bell.slash.fill")
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                        Button("Resume Now") {
                            notificationManager.resumeNotifications()
                        }
                        .controlSize(.small)
                    }
                } else {
                    HStack {
                        Spacer()
                        Button("Mute for 1 Hour", systemImage: "bell.slash") {
                            notificationManager.mute(for: 60 * 60)
                        }
                        .controlSize(.small)
                    }
                }

                if let error = notificationManager.lastDeliveryError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text(
                "Errors use Active delivery; warnings use Passive delivery. "
                + "Repeated events replace the same incident, bursts are summarized, "
                + "and Notification Center keeps the latest 40 incidents. "
                + "macOS controls banners versus persistent alerts, previews, sounds, and Focus."
            )
        }
    }

    private func notificationToggle(
        title: String,
        detail: String,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var notificationAuthorizationBadge: some View {
        if notificationManager.authorization == .allowed,
           !notificationManager.systemAlertsEnabled {
            Label("Alerts Off", systemImage: "bell.slash.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        } else {
            switch notificationManager.authorization {
            case .allowed:
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .denied:
                Label("Not Allowed", systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            case .notRequested:
                Text("Requested when enabled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .unavailable:
                Label("Unavailable", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var statusDetail: String {
        switch manager.state {
        case .running:
            "The signed core is verified and the local agent is available."
        case .starting:
            "Verifying core/config.yaml and signed history…"
        case .needsAttention:
            "Startup is paused until the workspace is repaired."
        case .crashed:
            "The process exited unexpectedly and may be retried."
        case .stopped:
            "Ready to verify and start."
        case .notConfigured:
            "Choose or install a Thane binary."
        }
    }

    private var statusIcon: String {
        switch manager.state {
        case .running: "checkmark.circle.fill"
        case .starting: "checkmark.shield"
        case .needsAttention: "exclamationmark.shield.fill"
        case .crashed: "exclamationmark.triangle.fill"
        case .stopped: "stop.circle"
        case .notConfigured: "questionmark.circle"
        }
    }

    private var stateColor: Color {
        switch manager.state {
        case .running: .green
        case .starting: .blue
        case .needsAttention: .orange
        case .crashed: .red
        case .stopped, .notConfigured: .secondary
        }
    }

    @ViewBuilder
    private var controlButtons: some View {
        switch manager.state {
        case .running:
            Button("Stop") { manager.stop() }
        case .stopped, .crashed:
            Button("Check & Start") { manager.start() }
                .buttonStyle(.borderedProminent)
                .disabled(manager.binaryURL == nil)
        case .needsAttention:
            Button("Check Again") { manager.start() }
                .buttonStyle(.borderedProminent)
        case .starting:
            ProgressView().controlSize(.small)
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
                    .frame(width: 90, alignment: .leading)

                Text(url?.path ?? placeholder)
                    .font(.caption.monospaced())
                    .foregroundStyle(url != nil ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                Spacer()

                Button("Choose…") {
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
                .padding(.leading, 90)
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
