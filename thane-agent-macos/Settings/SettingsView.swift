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
            Tab("Thane", systemImage: "brain.head.profile", value: .agent) {
                AgentSettingsView()
            }
            Tab("Capabilities", systemImage: "switch.2", value: .capabilities) {
                CapabilitiesSettingsView()
            }
            Tab("Calendar", systemImage: "calendar", value: .calendar) {
                CalendarSettingsView()
            }
            Tab("File Access", systemImage: "folder.badge.gearshape", value: .access) {
                FileAccessSettingsView()
            }
        }
        .frame(width: 680)
        .frame(minHeight: 560)
    }
}

// MARK: - Thane Tab

struct AgentSettingsView: View {
    @Environment(AppState.self) private var appState
    @Query(filter: #Predicate<ServerConfig> { $0.isDefault }) private var defaultConfigs: [ServerConfig]

    private var configurationMode: Binding<AgentConfigurationMode> {
        Binding(
            get: { appState.configurationMode },
            set: {
                appState.selectConfiguration(
                    $0,
                    advancedConfig: defaultConfigs.first
                )
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Configuration", selection: configurationMode) {
                    ForEach(AgentConfigurationMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(appState.configurationMode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            switch appState.configurationMode {
            case .managed:
                LocalServerSettingsView()
            case .advanced:
                ServerSettingsView()
            }
        }
    }
}

// MARK: - Advanced Connection

struct ServerSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Query private var configs: [ServerConfig]

    @State private var serverURL = ""
    @State private var token = ""
    @State private var showToken = false
    @State private var saveError: String?

    private var config: ServerConfig? { configs.first(where: \.isDefault) }

    /// Warns when the entered URL would be blocked by App Transport Security:
    /// plaintext http:// to a non-local host. Remote servers must use https://.
    private var insecureRemoteWarning: String? {
        guard let host = ServerConfig.insecurePlaintextHost(in: serverURL) else { return nil }
        return "macOS blocks plaintext HTTP to remote hosts (App Transport Security). Use https:// to reach \(host)."
    }

    var body: some View {
        Form {
            Section("Advanced Connection") {
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
                            saveAndConnect()
                        }
                        .disabled(serverURL.isEmpty || token.isEmpty)
                        Button("Disconnect") { appState.disconnect() }
                    } else {
                        Button("Connect") {
                            saveAndConnect()
                        }
                        .disabled(serverURL.isEmpty || token.isEmpty)
                    }
                }

                if let error = appState.connection.lastError {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }

                if let saveError {
                    Text(saveError)
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

    private func saveConfig() throws -> ServerConfig {
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
        try modelContext.save()
        return cfg
    }

    private func saveAndConnect() {
        do {
            let config = try saveConfig()
            saveError = nil
            appState.selectConfiguration(
                .advanced,
                advancedConfig: config,
                forceReconnect: true
            )
        } catch {
            saveError = "Couldn’t save this connection: \(error.localizedDescription)"
        }
    }
}

// MARK: - Managed Thane

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
                    Button("Agent Health…", systemImage: "waveform.path.ecg") {
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
                    Text("Automatic restart is paused for terminal exit 78. Agent Health shows the exact findings and repair commands.")
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

// MARK: - Calendar Tab

struct CalendarSettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var calendars: [CalendarMetadata] = []
    @State private var isLoading = false
    @State private var loadError: String?

    private var preferences: CalendarSharingPreferences {
        appState.calendarSharingPreferences
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: sharingEnabledBinding) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Share Calendar Data with Thane")
                        Text("Master gate for every calendar tool and response.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Label(sharingSummary, systemImage: preferences.isEnabled ? "checkmark.shield.fill" : "lock.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(preferences.isEnabled ? .green : .secondary)
            } header: {
                Text("Calendar Sharing")
            } footer: {
                Text("Calendar access and sharing are separate controls. Turning this off immediately blocks calendar metadata, event reads, and calendar mutations over the Thane connection while preserving your selections.")
            }

            Section {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("macOS Calendar Access")
                        Text("Required to discover calendars and read events selected below.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    EventKitAuthorizationControl(
                        status: appState.calendarAuthorization,
                        privacyPane: "Privacy_Calendars",
                        onRequest: { await appState.requestCalendarAccess() },
                        onRecheck: { await appState.refreshCalendarAuthorization() }
                    )
                }
                .padding(.vertical, 4)
            } header: {
                Text("Permission")
            }

            Section {
                calendarSelectionContent
            } header: {
                HStack {
                    Text("Calendars")
                    Spacer()
                    if appState.calendarAuthorization == .fullAccess {
                        Button("Refresh") {
                            Task { await loadCalendars() }
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .disabled(isLoading)
                    }
                }
            } footer: {
                Text("Only checked calendars can leave this app. Descriptions are authored here and shared as context so Thane can understand each calendar’s scope and intended use. A calendar whose EventKit identifier changes after an account re-sync must be selected again.")
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            await appState.refreshCalendarAuthorization()
            if appState.calendarAuthorization == .fullAccess {
                await loadCalendars()
            }
        }
        .onChange(of: appState.calendarAuthorization) { _, status in
            guard status == .fullAccess else {
                calendars = []
                return
            }
            Task { await loadCalendars() }
        }
    }

    @ViewBuilder
    private var calendarSelectionContent: some View {
        switch appState.calendarAuthorization {
        case .fullAccess:
            if isLoading && calendars.isEmpty {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading calendars…")
                        .foregroundStyle(.secondary)
                }
            } else if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } else if calendars.isEmpty {
                Text("No event calendars are available on this Mac.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(calendars) { calendar in
                    calendarRow(calendar)
                }
            }
        case .notDetermined:
            Text("Grant Calendar access to choose which calendars Thane may use.")
                .foregroundStyle(.secondary)
        case .denied, .restricted, .writeOnly, .unknown:
            Text("Full Calendar access is required to configure the sharing allowlist.")
                .foregroundStyle(.secondary)
        }
    }

    private func calendarRow(_ calendar: CalendarMetadata) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: sharedBinding(for: calendar.calendarIdentifier)) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(calendarColor(calendar.color))
                        .frame(width: 10, height: 10)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(calendar.title)
                            if calendar.isDefault {
                                Text("Default")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(calendarDetail(calendar))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.checkbox)

            if preferences.isShared(calendar.calendarIdentifier) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Description for Thane")
                        .font(.caption.weight(.medium))
                    TextField(
                        "Scope, intended use, and any guidance Thane should know",
                        text: descriptionBinding(for: calendar.calendarIdentifier),
                        axis: .vertical
                    )
                    .lineLimit(2...5)
                    Text("\(preferences.description(for: calendar.calendarIdentifier).count)/\(CalendarSharingPreferences.maxDescriptionLength)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.leading, 22)
            }
        }
        .padding(.vertical, 4)
    }

    private var sharingEnabledBinding: Binding<Bool> {
        Binding(
            get: { preferences.isEnabled },
            set: { preferences.isEnabled = $0 }
        )
    }

    private func sharedBinding(for identifier: String) -> Binding<Bool> {
        Binding(
            get: { preferences.isShared(identifier) },
            set: { preferences.setShared($0, for: identifier) }
        )
    }

    private func descriptionBinding(for identifier: String) -> Binding<String> {
        Binding(
            get: { preferences.description(for: identifier) },
            set: { preferences.setDescription($0, for: identifier) }
        )
    }

    private var sharingSummary: String {
        guard preferences.isEnabled else {
            return "Calendar sharing is off."
        }
        let count = preferences.sharedCalendarCount
        return count == 1 ? "1 calendar is shared." : "\(count) calendars are shared."
    }

    private func calendarDetail(_ calendar: CalendarMetadata) -> String {
        let access = calendar.allowsContentModifications ? "Read & write" : "Read only"
        return "\(calendar.source.title) · \(calendar.type.capitalized) · \(access)"
    }

    private func calendarColor(_ hex: String?) -> Color {
        guard let hex,
              hex.count == 7,
              hex.first == "#",
              let value = UInt64(hex.dropFirst(), radix: 16) else {
            return .secondary
        }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    private func loadCalendars() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            calendars = try await appState.calendarService.availableCalendars()
        } catch {
            calendars = []
            loadError = "Couldn’t load calendars: \(error.localizedDescription)"
        }
    }
}

private struct EventKitAuthorizationControl: View {
    let status: EventKitAuthorizationState
    let privacyPane: String
    let onRequest: () async -> Void
    let onRecheck: () async -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            statusBadge
            actionButton
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
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
    private var actionButton: some View {
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
                if let url = URL(
                    string: "x-apple.systempreferences:com.apple.preference.security?\(privacyPane)"
                ) {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}

// MARK: - Capabilities Tab

struct CapabilitiesSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Shared only with your connected Thane", systemImage: "lock.shield.fill")
                        .font(.headline)
                    Text("System context is read on demand over the authenticated platform connection. It is not published as Home Assistant entities or retained by this app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(systemContextSummary)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(
                            appState.systemContextPreferences.hasEnabledCategories
                                ? .green
                                : .secondary
                        )
                }
                .padding(.vertical, 4)

                ForEach(SystemContextCategory.allCases) { category in
                    systemContextRow(category)
                }
            } header: {
                Text("System Context")
            } footer: {
                Text("These signals use macOS system APIs and do not require an Apple privacy prompt. All categories are off until you choose to share them.")
            }

            Section {
                remindersRow
                contactsRow
            } header: {
                Text("Apple Data")
            } footer: {
                Text("These grants power the macOS platform tools exposed back to a connected Thane server.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            Task {
                await appState.refreshContactsAuthorization()
                await appState.refreshRemindersAuthorization()
            }
        }
    }

    private var systemContextSummary: String {
        let count = appState.systemContextPreferences.enabledCategories.count
        return count == 0
            ? "Nothing is currently shared."
            : "\(count) of \(SystemContextCategory.allCases.count) categories enabled."
    }

    private func systemContextRow(_ category: SystemContextCategory) -> some View {
        Toggle(
            isOn: Binding(
                get: { appState.systemContextPreferences.bindingValue(for: category) },
                set: { appState.systemContextPreferences.setEnabled($0, for: category) }
            )
        ) {
            VStack(alignment: .leading, spacing: 3) {
                Text(category.title)
                Text(category.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
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

            EventKitAuthorizationControl(
                status: appState.remindersAuthorization,
                privacyPane: "Privacy_Reminders",
                onRequest: { await appState.requestRemindersAccess() },
                onRecheck: { await appState.refreshRemindersAuthorization() }
            )
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

// MARK: - File Access Tab

struct FileAccessSettingsView: View {
    @Environment(AppState.self) private var appState

    private var manager: PermissionsManager { appState.permissionsManager }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Full Disk Access", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Text("Grants the managed Thane process unrestricted file access, including protected locations outside your home folder. macOS requires you to approve this manually.")
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
            } header: {
                Text("Broad Access")
            } footer: {
                Text("Full Disk Access applies to the local managed process. It does not control which macOS capabilities are shared over the Thane connection.")
            }

            Section {
                ForEach(manager.categories) { category in
                    categoryRow(category)
                }
            } header: {
                Text("Approved Locations")
            } footer: {
                Text("Approve only the folders the managed Thane instance needs for unattended work.")
            }

            Section {
                HStack {
                    Spacer()
                    Button("Add Location…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.allowsMultipleSelection = false
                        panel.message = "Choose a directory for Thane to access"
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
                await manager.refreshPreviouslyRequested()
            }
        }
    }

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
}

// MARK: - General Tab

struct GeneralSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var loginItemStatus = SMAppService.mainApp.status
    @State private var portBrokerStatus = PortBroker.status
    @State private var portBrokerError: String?

    private var portBrokerBinding: Binding<Bool> {
        Binding(
            get: { portBrokerStatus == .enabled || portBrokerStatus == .requiresApproval },
            set: { enable in
                do {
                    portBrokerError = nil
                    if enable {
                        try PortBroker.register()
                    } else {
                        try PortBroker.unregister()
                    }
                } catch {
                    portBrokerError = error.localizedDescription
                }
                portBrokerStatus = PortBroker.status
            }
        )
    }

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
        @Bindable var appState = appState

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

            Section {
                Toggle("Hold ports 443 and 80 for Thane", isOn: portBrokerBinding)
                if portBrokerStatus == .requiresApproval {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.yellow)
                        Text("Approval required in System Settings → General → Login Items & Extensions.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Open…") {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                        .font(.caption)
                    }
                }
                if let portBrokerError {
                    Text(portBrokerError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Privileged Ports")
            } footer: {
                Text("macOS refuses ports below 1024 to ordinary users. This registers a small daemon under this app's name so launchd binds 443 and 80 at boot and hands them to Thane's HTTPS front door; Thane itself never runs with privilege. Takes effect the next time Thane starts.")
            }

            Section {
                Picker("Menu bar", selection: $appState.menuBarTextStyle) {
                    ForEach(MenuBarTextStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
            } header: {
                Text("Menu Bar")
            } footer: {
                Text("The icon always reflects connection, attention, and update state. Text can add the current status or managed Thane version.")
            }

            Section("Application Updates") {
                AppUpdateSettingsSection()
            }
        }
        .formStyle(.grouped)
        .onAppear {
            loginItemStatus = SMAppService.mainApp.status
            portBrokerStatus = PortBroker.status
        }
    }
}
