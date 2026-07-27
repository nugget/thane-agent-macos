import Darwin.POSIX
import Foundation
import os

/// Manages a local `thane` binary as a child process.
///
/// Lifecycle: find → verify signed core → start → running → stop/crash → stopped
///
/// The canonical managed install location is ~/Thane/bin/thane, matching
/// the .pkg installer and the default workspace. For development, we also
/// probe common PATH locations. Users can always point us at an arbitrary
/// path via the Settings UI.
///
/// When the binary on disk changes (for example, after a package install,
/// replacement, or manual copy), a filesystem watcher re-inspects the code
/// signature. If the new binary is signed by the same Team ID, the process
/// is restarted automatically. Signature mismatches are surfaced without
/// restarting.
/// Subset of thane's config.yaml relevant to the macOS app.
/// Parsed on a best-effort basis — always falls back to defaults.
///
/// Marked `nonisolated` so the test target — which runs under the
/// project's default-MainActor isolation — can call `parse(...)` and
/// read fields without actor hops. Without this, `xcodebuild test`
/// rejects every reference with "Main actor-isolated ... can not be
/// referenced from a nonisolated context."
nonisolated struct LocalThaneConfig: Sendable {
    var nativePort: Int = 8080
    var ollamaPort: Int = 11434
    /// Whether the companion WebSocket endpoint is enabled in the parsed
    /// config. Sourced from the `companion.enabled` key.
    var companionEnabled: Bool = false
    /// First token discovered under `companion.providers.<name>.tokens`.
    /// The server's tokenIndex resolves any valid token to the correct
    /// account, so the macOS app doesn't need to know which provider it
    /// represents.
    var companionToken: String? = nil

    static let defaults = LocalThaneConfig()

    // MARK: - Parsing

    /// Parse the subset of thane's config.yaml that the macOS app needs.
    /// Returns `.defaults` if the file is missing or unreadable.
    static func parse(at url: URL) -> LocalThaneConfig {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return .defaults
        }
        return parse(yaml: content)
    }

    /// Parse a config.yaml string. Uses a simple line-based approach —
    /// no YAML library required.
    ///
    /// Recognized companion shape:
    ///   companion:
    ///     enabled: true
    ///     providers:
    ///       <account>:
    ///         tokens:
    ///         - <token>
    static func parse(yaml content: String) -> LocalThaneConfig {
        var result = LocalThaneConfig()
        var topSection = ""
        var inTokensList = false

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), !trimmed.isEmpty else { continue }
            let indent = line.prefix(while: { $0 == " " }).count

            // Top-level section key
            if indent == 0 && trimmed.hasSuffix(":") && !trimmed.contains(" ") {
                topSection = String(trimmed.dropLast())
                inTokensList = false
                continue
            }

            switch topSection {
            case "listen":
                if let p = parseYAMLPort(trimmed) { result.nativePort = p }

            case "ollama_api":
                if let p = parseYAMLPort(trimmed) { result.ollamaPort = p }

            case "companion":
                // `tokens:` lines appear once per provider in the new shape;
                // the flat line scan handles that transparently — we keep
                // only the first token seen.
                if trimmed == "enabled: true"  { result.companionEnabled = true }
                if trimmed == "enabled: false" { result.companionEnabled = false }
                if trimmed == "tokens:" {
                    inTokensList = true
                } else if inTokensList && trimmed.hasPrefix("- ") {
                    if result.companionToken == nil {
                        result.companionToken = extractYAMLListValue(trimmed)
                    }
                } else if inTokensList && !trimmed.hasPrefix("- ") {
                    inTokensList = false
                }

            default: break
            }
        }

        return result
    }

    private static func parseYAMLPort(_ trimmed: String) -> Int? {
        guard trimmed.hasPrefix("port:") else { return nil }
        return Int(trimmed.dropFirst("port:".count).trimmingCharacters(in: .whitespaces))
    }

    private static func extractYAMLListValue(_ trimmed: String) -> String? {
        var value = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
           (value.hasPrefix("'")  && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        return value.isEmpty ? nil : value
    }
}

@Observable
@MainActor
final class BinaryManager {

    // MARK: - State

    enum State: Equatable {
        case notConfigured      // no binary found or set
        case stopped
        case starting
        case running(pid: Int32)
        case crashed(code: Int32)
        case needsAttention(code: Int32)

        var label: String {
            switch self {
            case .notConfigured:    "Not Configured"
            case .stopped:          "Stopped"
            case .starting:         "Starting…"
            case .running:          "Running"
            case .crashed(let c):   "Crashed (exit \(c))"
            case .needsAttention:   "Needs Attention"
            }
        }

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    // MARK: - Health

    enum HealthStatus: String {
        case healthy   = "Healthy"
        case degraded  = "Degraded"
        case crashLoop = "Crash Loop"
        case attention = "Needs Attention"
        case stopped   = "Stopped"
    }

    struct ProcessStats {
        var cpuPercent: Double = 0
        var residentMemoryMB: Double = 0
        var threadCount: Int = 0
    }

    struct RuntimeLogEntry: Identifiable {
        let id = UUID()
        let date: Date
        let message: String
        let isError: Bool
    }

    /// How the managed binary was installed. Determines what trust signals
    /// are meaningful to display — a bare CLI binary cannot carry a stapled
    /// notarization ticket, so package-level notarization is tracked here.
    enum InstallProvenance: String {
        case unknown            // binary was found on disk, no install history
        case notarizedPackage   // installed from a notarized .pkg
        case signedPackage      // installed from a signed but not notarized .pkg
        case unsignedPackage    // installed from an unsigned .pkg
        case manual             // filesystem watcher detected an external change
    }

    // MARK: - Properties

    private(set) var state: State = .notConfigured {
        didSet { onStateChange?(state) }
    }
    private(set) var startedAt: Date?
    private(set) var detectedVersion: String?
    private(set) var localConfig: LocalThaneConfig = .defaults
    private(set) var lastValidationReport: ThaneValidationReport?
    private(set) var lastTerminalMessage: String?
    private(set) var recentLogs: [RuntimeLogEntry] = []

    /// Called whenever state changes. AppState uses this to auto-connect the WebSocket.
    var onStateChange: ((State) -> Void)?

    /// URL of the thane binary. Set by the user or discovered automatically.
    var binaryURL: URL? {
        didSet {
            UserDefaults.standard.set(binaryURL?.path, forKey: "binaryPath")
            binarySignatureMismatch = false
            if !isPerformingMaintenance {
                installProvenance = .unknown
            }
            refreshState()
            updateBinaryMtime()
            Task { await refreshCodeSignature() }
            startWatchingBinary()
            if oldValue != binaryURL, state.isRunning {
                restart()
            }
        }
    }

    /// Root containing the signed `core/` directory. Thane receives this path
    /// explicitly through `-workspace`; the process CWD is not trusted for
    /// configuration discovery. Defaults to ~/Thane/ on first run.
    var workspaceURL: URL {
        didSet {
            UserDefaults.standard.set(workspaceURL.path, forKey: "workspacePath")
            guard oldValue != workspaceURL else { return }
            lastValidationReport = nil
            lastTerminalMessage = nil
            if state.isRunning {
                restart()
            } else if state == .starting {
                stop()
            } else {
                refreshState()
            }
        }
    }

    /// The only normal runtime config location: the signed config inside core.
    var canonicalConfigURL: URL {
        ThaneInvocation.canonicalConfigURL(workspace: workspaceURL)
    }

    private(set) var codeSignature: AppleCodeSignature?

    /// How the current binary was installed. Persisted so it survives app restarts.
    private(set) var installProvenance: InstallProvenance {
        didSet { UserDefaults.standard.set(installProvenance.rawValue, forKey: "installProvenance") }
    }

    private(set) var processStats = ProcessStats()
    private(set) var recentCrashCount = 0

    var healthStatus: HealthStatus {
        switch state {
        case .running:
            if recentCrashCount >= 2 { return .degraded }
            return .healthy
        case .crashed:
            if recentCrashCount >= 3 { return .crashLoop }
            return .degraded
        case .starting:
            return recentCrashCount >= 3 ? .crashLoop : .healthy
        case .needsAttention:
            return .attention
        case .stopped, .notConfigured:
            return .stopped
        }
    }

    /// True when the last filesystem change produced a signature mismatch.
    /// Surfaced in the UI so the user knows the binary on disk isn't trusted.
    private(set) var binarySignatureMismatch = false

    /// True when the running binary's major version doesn't match the app's.
    private(set) var versionIncompatible = false

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var startTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    private var binaryWatcher: DirectoryWatcher?
    private var binaryWatchDebounce: Task<Void, Never>?
    private var lastKnownBinaryMtime: Date?
    private var isPerformingMaintenance = false
    private var restartAttempt = 0
    private var recentCrashTimestamps: [Date] = []
    private let logger = Logger(subsystem: "info.nugget.thane-agent-macos", category: "binary")

    /// Whether the server should be running. Persisted across launches.
    private var shouldRun: Bool {
        get { UserDefaults.standard.bool(forKey: "localServerShouldRun") }
        set { UserDefaults.standard.set(newValue, forKey: "localServerShouldRun") }
    }

    // MARK: - Discovery

    /// Canonical managed install location, matching the .pkg installer
    /// and the default ~/Thane/ workspace.
    static var managedBinaryURL: URL {
        URL.homeDirectory.appending(components: "Thane", "bin", "thane")
    }

    /// Ordered list of paths to probe during auto-discovery.
    static var searchPaths: [URL] {
        [
            managedBinaryURL,
            URL(fileURLWithPath: "/usr/local/bin/thane"),
            URL(fileURLWithPath: "/opt/homebrew/bin/thane"),
            URL(fileURLWithPath: ("~/.local/bin/thane" as NSString).expandingTildeInPath),
        ]
    }

    // MARK: - Init

    init() {
        installProvenance = UserDefaults.standard.string(forKey: "installProvenance")
            .flatMap { InstallProvenance(rawValue: $0) } ?? .unknown
        // Restore previously saved path, or auto-discover.
        if let path = UserDefaults.standard.string(forKey: "binaryPath") {
            binaryURL = URL(fileURLWithPath: path)
        } else {
            binaryURL = Self.searchPaths.first {
                FileManager.default.fileExists(atPath: $0.path)
            }
        }
        workspaceURL = UserDefaults.standard.string(forKey: "workspacePath")
            .map { URL(fileURLWithPath: $0) }
            ?? URL.homeDirectory.appending(path: "Thane")
        // PR 1260 retired arbitrary config selection from the normal runtime.
        // Discard the app's old preference so it cannot silently opt a managed
        // instance out of signed-core verification.
        UserDefaults.standard.removeObject(forKey: "configPath")
        refreshState()
        updateBinaryMtime()
        Task { await refreshCodeSignature() }
        startWatchingBinary()
    }

    // MARK: - Lifecycle

    /// Called by AppState after registering onStateChange, so the callback is ready before any auto-start.
    /// Probes the workspace directory at startup — a hard failure if inaccessible — then auto-starts
    /// if the server was running when the app last quit. All other TCC probing is user-initiated
    /// via the Permissions settings tab.
    func autoStartIfNeeded() {
        guard shouldRun, case .stopped = state else { return }
        let workspace = workspaceURL
        Task { [weak self] in
            guard let self else { return }
            let accessError = await Task.detached(priority: .utility) {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: workspace.path, isDirectory: &isDirectory) else {
                    // A missing first-run workspace is a valid state. Let
                    // structured preflight describe it and offer initialization.
                    return nil as String?
                }
                guard isDirectory.boolValue else {
                    return "The workspace path exists but is not a directory."
                }
                do {
                    _ = try FileManager.default.contentsOfDirectory(atPath: workspace.path)
                    return nil as String?
                } catch {
                    return error.localizedDescription
                }
            }.value
            if let accessError {
                logger.error("Workspace is inaccessible at startup: \(workspace.path, privacy: .public); auto-start aborted: \(accessError, privacy: .public)")
                append("Auto-start aborted: workspace is inaccessible at \(workspace.path)", isError: true)
                shouldRun = false
                return
            }

            logger.info("Auto-starting local server (shouldRun=true from previous session)")
            start()
        }
    }

    func start() {
        startTask?.cancel()
        startTask = nil
        restartTask?.cancel()
        restartTask = nil
        guard let url = binaryURL,
              FileManager.default.fileExists(atPath: url.path) else { return }
        switch state {
        case .stopped, .crashed, .needsAttention:
            break
        case .notConfigured, .starting, .running:
            return
        }

        shouldRun = true
        state = .starting
        detectedVersion = nil
        lastCPUSample = nil
        lastValidationReport = nil
        lastTerminalMessage = nil
        recentLogs.removeAll()

        let workspace = workspaceURL
        let configURL = canonicalConfigURL
        startTask = Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let config = LocalThaneConfig.parse(at: configURL)
                    let workingDirectory = Self.commandWorkingDirectory(for: workspace)
                    let validation = try ThaneProcessRunner.run(
                        executable: url,
                        arguments: ThaneInvocation.validationArguments(workspace: workspace),
                        workingDirectory: workingDirectory
                    )
                    return (config, validation)
                }.value
                guard let self, !Task.isCancelled, shouldRun, state == .starting else { return }
                localConfig = result.0
                handlePreflight(result.1, binaryURL: url)
            } catch {
                guard let self, !Task.isCancelled else { return }
                shouldRun = false
                state = .crashed(code: 1)
                lastTerminalMessage = "Could not validate this workspace: \(error.localizedDescription)"
                append(lastTerminalMessage ?? "Validation failed", isError: true)
            }
        }
    }

    private func handlePreflight(_ outcome: ThaneProcessOutcome, binaryURL: URL) {
        let report = ThaneValidationReport.parse(outcome.stdout)
        lastValidationReport = report

        if let report {
            guard report.passed, outcome.exitCode == 0 else {
                shouldRun = false
                state = .needsAttention(code: outcome.exitCode)
                lastTerminalMessage = report.operatorSummary
                append("Startup blocked: \(report.operatorSummary)", isError: true)
                logger.error("Core preflight failed; refusing to start local thane (exit \(outcome.exitCode))")
                return
            }
            append("Signed core verified", isError: false)
            launchServe(binaryURL: binaryURL)
            return
        }

        shouldRun = false
        let combinedOutput = (outcome.stdout + "\n" + outcome.stderr)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        lastTerminalMessage = combinedOutput.isEmpty
            ? "This Thane version cannot prove signed-core integrity. Update Thane before starting it from this app."
            : combinedOutput
        state = .needsAttention(
            code: outcome.exitCode == 0 ? ThaneInvocation.terminalExitCode : outcome.exitCode
        )
        append(lastTerminalMessage ?? "Signed-core validation was unavailable", isError: true)
        logger.error("Thane did not emit a structured integrity report; refusing to start")
    }

    private func launchServe(binaryURL: URL) {
        guard shouldRun, state == .starting else { return }
        let proc = Process()
        proc.executableURL = binaryURL
        proc.currentDirectoryURL = workspaceURL
        proc.arguments = ThaneInvocation.serveArguments(workspace: workspaceURL)

        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        stdoutPipe = out
        stderrPipe = err

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in self?.append(text, isError: false) }
        }

        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in self?.append(text, isError: true) }
        }

        proc.terminationHandler = { [weak self] p in
            Task { @MainActor [weak self] in self?.handleTermination(code: p.terminationStatus) }
        }

        do {
            try proc.run()
            process = proc
            startedAt = Date()
            restartAttempt = 0
            state = .running(pid: proc.processIdentifier)
            startStatsPolling(pid: proc.processIdentifier)
            append("thane started (pid \(proc.processIdentifier))", isError: false)
            logger.info("thane started, pid \(proc.processIdentifier)")
        } catch {
            state = .stopped
            append("Failed to start: \(error.localizedDescription)", isError: true)
            logger.error("Failed to start thane: \(error.localizedDescription)")
        }
    }

    func stop() {
        shouldRun = false
        startTask?.cancel()
        startTask = nil
        restartTask?.cancel()
        restartTask = nil
        if case .starting = state {
            state = .stopped
            return
        }
        guard state.isRunning else { return }
        process?.terminate()
        // State update happens in terminationHandler.
    }

    /// Stop in-flight launch work and signal the managed child before the app
    /// exits, while preserving `shouldRun` so launch-at-login can restore the
    /// operator's intent next time.
    func prepareForApplicationTermination() {
        startTask?.cancel()
        restartTask?.cancel()
        statsTask?.cancel()
        process?.terminate()
    }

    func restart() {
        if state.isRunning {
            // terminationHandler will not auto-restart; we trigger manually after stop.
            Task {
                stop()
                // Give the process a moment to exit cleanly.
                try? await Task.sleep(for: .milliseconds(500))
                start()
            }
        } else {
            start()
        }
    }

    var canInitializeWorkspace: Bool {
        lastValidationReport?.integrity?.failures.contains {
            $0.name == "core_directory"
        } == true
    }

    /// Create the workspace's signed core using thane's own idempotent
    /// bootstrap, then immediately run the normal verification-and-start path.
    func initializeWorkspace() {
        guard canInitializeWorkspace, let binaryURL else { return }

        startTask?.cancel()
        restartTask?.cancel()
        state = .starting
        shouldRun = true
        append("Initializing the signed workspace…", isError: false)

        let workspace = workspaceURL
        startTask = Task { [weak self] in
            do {
                let outcome = try await Task.detached(priority: .userInitiated) {
                    try ThaneProcessRunner.run(
                        executable: binaryURL,
                        arguments: ThaneInvocation.initializationArguments(workspace: workspace),
                        workingDirectory: Self.commandWorkingDirectory(for: workspace)
                    )
                }.value
                guard let self, !Task.isCancelled else { return }
                guard outcome.exitCode == 0 else {
                    shouldRun = false
                    state = outcome.exitCode == ThaneInvocation.terminalExitCode
                        ? .needsAttention(code: outcome.exitCode)
                        : .crashed(code: outcome.exitCode)
                    let message = outcome.stderr.isEmpty ? outcome.stdout : outcome.stderr
                    lastTerminalMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
                    append(lastTerminalMessage ?? "Workspace initialization failed", isError: true)
                    return
                }

                append("Workspace initialized", isError: false)
                state = .stopped
                startTask = nil
                start()
            } catch {
                guard let self, !Task.isCancelled else { return }
                shouldRun = false
                state = .crashed(code: 1)
                lastTerminalMessage = "Could not initialize this workspace: \(error.localizedDescription)"
                append(lastTerminalMessage ?? "Workspace initialization failed", isError: true)
            }
        }
    }

    // MARK: - Code Signature

    func refreshCodeSignature() async {
        guard let url = binaryURL else {
            codeSignature = nil
            return
        }
        codeSignature = await AppleCodeSignature.inspect(binaryURL: url)
    }

    // MARK: - Version Compatibility

    private func checkVersionCompatibility() {
        guard let detected = detectedVersion,
              let binarySemver = SemanticVersion(detected),
              let appSemver = AppVersion.semver else {
            versionIncompatible = false
            return
        }
        versionIncompatible = binarySemver.major != appSemver.major
        if versionIncompatible {
            logger.warning("Binary version \(detected) has different major version than app \(AppVersion.current)")
        }
    }

    /// Record how the binary was installed. Called by UpdateManager after
    /// verifying the installer package.
    func setInstallProvenance(_ provenance: InstallProvenance) {
        installProvenance = provenance
    }

    // MARK: - Maintenance

    /// Stop the binary, perform an action (e.g. replacing the executable), then
    /// restart if it was previously running. Used by UpdateManager for updates.
    /// Suppresses the filesystem watcher during the operation so the managed
    /// install doesn't race with watcher-triggered provenance resets.
    func performMaintenance(_ action: @Sendable () throws -> Void) async throws {
        isPerformingMaintenance = true
        defer { isPerformingMaintenance = false }

        let previousShouldRun = shouldRun
        if state.isRunning { stop() }

        // Wait for process to exit
        var waitIterations = 0
        while state.isRunning && waitIterations < 50 {
            try await Task.sleep(for: .milliseconds(100))
            waitIterations += 1
        }

        try action()

        // Update mtime so the watcher doesn't treat this as an external change
        updateBinaryMtime()

        if previousShouldRun {
            start()
        }
    }

    // MARK: - Binary Filesystem Watch

    /// Watch the binary's parent directory for changes. When the binary is
    /// replaced on disk (e.g. by `installer -pkg` or manual copy), we
    /// re-inspect the code signature and decide whether to auto-restart.
    private func startWatchingBinary() {
        stopWatchingBinary()
        guard let url = binaryURL else { return }

        let dirPath = url.deletingLastPathComponent().path
        guard FileManager.default.fileExists(atPath: dirPath) else { return }

        binaryWatcher = DirectoryWatcher(path: dirPath) { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleBinaryDirectoryChange()
            }
        }
        logger.info("Watching \(dirPath) for binary changes")
    }

    private func stopWatchingBinary() {
        binaryWatcher = nil
        binaryWatchDebounce?.cancel()
        binaryWatchDebounce = nil
    }

    /// Debounce filesystem events — `installer -pkg` can trigger several
    /// writes in quick succession. Wait for events to settle before acting.
    private func handleBinaryDirectoryChange() {
        binaryWatchDebounce?.cancel()
        binaryWatchDebounce = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            await self?.evaluateBinaryChange()
        }
    }

    private func updateBinaryMtime() {
        guard let url = binaryURL else { return }
        lastKnownBinaryMtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func evaluateBinaryChange() async {
        guard !isPerformingMaintenance else { return }
        guard let url = binaryURL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.info("Binary no longer exists at \(url.path)")
            return
        }

        // Check if the binary itself actually changed (not just another file in the dir)
        let currentMtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if let known = lastKnownBinaryMtime, let current = currentMtime, known == current {
            return // Binary didn't change, some other file in the directory did
        }
        lastKnownBinaryMtime = currentMtime

        let previousTeamID = codeSignature?.teamID
        let newSignature = await AppleCodeSignature.inspect(binaryURL: url)

        // Always update the displayed signature and invalidate stale
        // package provenance — the binary on disk is no longer the one
        // we installed, regardless of whether the new one is trusted.
        codeSignature = newSignature
        installProvenance = .manual

        // Determine trust: same Team ID means this is a legitimate update
        let trusted: Bool
        if let previousTeam = previousTeamID, let newTeam = newSignature.teamID {
            trusted = previousTeam == newTeam
        } else if previousTeamID == nil && newSignature.teamID != nil {
            // Upgrading from unsigned to signed — trust it
            trusted = true
        } else if previousTeamID == nil && newSignature.teamID == nil {
            // Both unsigned — could be dev builds, allow it
            trusted = true
        } else {
            // Had a team ID, now doesn't — suspicious
            trusted = false
        }

        if trusted {
            binarySignatureMismatch = false
            logger.info("Binary changed on disk with trusted signature, restarting")
            if state.isRunning {
                restart()
            }
        } else {
            binarySignatureMismatch = true
            logger.warning("Binary changed on disk with mismatched signature (was: \(previousTeamID ?? "nil"), now: \(newSignature.teamID ?? "nil")) — not restarting")
        }
    }

    // MARK: - Private

    private func handleTermination(code: Int32) {
        startTask = nil
        statsTask?.cancel()
        statsTask = nil
        processStats = ProcessStats()

        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe = nil
        process = nil
        startedAt = nil

        let clean = (code == 0 || code == SIGTERM)
        if clean {
            recentCrashTimestamps.removeAll()
            recentCrashCount = 0
            state = .stopped
            append("thane stopped", isError: false)
        } else if code == ThaneInvocation.terminalExitCode {
            shouldRun = false
            state = .needsAttention(code: code)
            let diagnostic = recentLogs
                .filter(\.isError)
                .suffix(16)
                .map(\.message)
                .joined(separator: "\n")
            if !diagnostic.isEmpty {
                lastTerminalMessage = diagnostic
            }
            append("Thane requires operator attention and will not be restarted automatically", isError: true)
            logger.error("thane exited with terminal code \(code); automatic restart disabled")
        } else {
            recentCrashTimestamps.append(Date())
            pruneStaleCrashes()
            state = .crashed(code: code)
            append("thane exited with code \(code)", isError: true)
            logger.error("thane crashed, exit code \(code)")
        }

        if !clean && code != ThaneInvocation.terminalExitCode && shouldRun {
            scheduleRestart()
        }
    }

    private func scheduleRestart() {
        restartAttempt += 1
        // Exponential backoff: 2, 4, 8, 16, 32, 60 seconds (capped).
        let delay = min(Double(1 << min(restartAttempt, 6)), 60.0)
        append("Restarting in \(Int(delay))s (attempt \(restartAttempt))…", isError: false)
        logger.info("Scheduling restart in \(delay)s (attempt \(self.restartAttempt))")

        restartTask = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard shouldRun else { return }
            start()
        }
    }

    private func append(_ text: String, isError: Bool) {
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if isError {
                logger.error("\(trimmed, privacy: .public)")
            } else {
                logger.info("\(trimmed, privacy: .public)")
            }
            recentLogs.append(RuntimeLogEntry(date: Date(), message: trimmed, isError: isError))
            if recentLogs.count > 250 {
                recentLogs.removeFirst(recentLogs.count - 250)
            }
            if detectedVersion == nil, let parsed = parseJSONLine(trimmed) {
                detectedVersion = parsed.version
                checkVersionCompatibility()
            }
        }
    }

    private struct ParsedLine { let version: String? }

    nonisolated private static func commandWorkingDirectory(for workspace: URL) -> URL {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: workspace.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return workspace
        }
        let parent = workspace.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return parent
        }
        return .homeDirectory
    }

    private func parseJSONLine(_ line: String) -> ParsedLine? {
        guard line.hasPrefix("{"),
              let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = obj["thane_version"] as? String
        else { return nil }
        return ParsedLine(version: version)
    }

    private func refreshState() {
        guard !state.isRunning, state != .starting else { return }
        if let url = binaryURL, FileManager.default.fileExists(atPath: url.path) {
            state = .stopped
        } else {
            state = .notConfigured
        }
    }

    // MARK: - Stats Polling

    private func startStatsPolling(pid: Int32) {
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.collectStats(pid: pid)
                // Also prune the crash window so Degraded / Crash Loop state
                // decays when the process stabilizes, instead of staying sticky
                // until the next crash.
                self?.pruneStaleCrashes()
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
            }
        }
    }

    /// Drop crash timestamps older than the 5-minute window and republish the
    /// count so `@Observable` consumers re-render. Cheap no-op when the list
    /// is empty or already up to date.
    private func pruneStaleCrashes() {
        let cutoff = Date().addingTimeInterval(-300)
        let pruned = recentCrashTimestamps.filter { $0 > cutoff }
        if pruned.count != recentCrashTimestamps.count {
            recentCrashTimestamps = pruned
        }
        if recentCrashCount != pruned.count {
            recentCrashCount = pruned.count
        }
    }

    nonisolated private func readProcessStats(pid: Int32) -> ProcessStats? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size)
        guard result == size else { return nil }

        let residentMB = Double(info.pti_resident_size) / (1024 * 1024)
        let totalTimeNS = info.pti_total_user + info.pti_total_system
        let threads = Int(info.pti_threadnum)

        return ProcessStats(
            cpuPercent: Double(totalTimeNS),  // raw nanoseconds, we diff below
            residentMemoryMB: residentMB,
            threadCount: threads
        )
    }

    private var lastCPUSample: (time: Date, ns: Double)?

    private func collectStats(pid: Int32) {
        guard let raw = readProcessStats(pid: pid) else { return }

        var stats = raw
        let now = Date()
        if let last = lastCPUSample {
            let wallElapsed = now.timeIntervalSince(last.time)
            if wallElapsed > 0 {
                let cpuDeltaNS = raw.cpuPercent - last.ns
                stats.cpuPercent = (cpuDeltaNS / (wallElapsed * 1_000_000_000)) * 100
            }
        }
        lastCPUSample = (time: now, ns: raw.cpuPercent)
        processStats = stats
    }

}

// MARK: - Directory Watcher

/// Wraps a kqueue-based `DispatchSource` for filesystem monitoring.
///
/// Lives outside the `@MainActor` default isolation so that the GCD event
/// handler runs cleanly on a utility queue without triggering
/// `dispatch_assert_queue_fail`. The `onChange` callback is `@Sendable`
/// and expected to hop to the main actor itself.
nonisolated final class DirectoryWatcher: @unchecked Sendable {
    private var source: (any DispatchSourceFileSystemObject)?

    init(path: String, onChange: @escaping @Sendable () -> Void) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .global(qos: .utility)
        )
        src.setEventHandler(handler: onChange)
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    deinit {
        source?.cancel()
    }
}
