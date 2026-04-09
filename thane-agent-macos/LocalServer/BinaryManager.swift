import Darwin.POSIX
import Foundation
import os

/// Manages a local `thane` binary as a child process.
///
/// Lifecycle: find → start → running → stop/crash → stopped
///
/// The canonical managed install location is ~/Thane/bin/thane, matching
/// the .pkg installer and the default workspace. For development, we also
/// probe common PATH locations. Users can always point us at an arbitrary
/// path via the Settings UI.
///
/// When the binary on disk changes (e.g. via `deploy-macos-pkg` or manual
/// copy), a filesystem watcher re-inspects the code signature. If the new
/// binary is signed by the same Team ID, the process is restarted
/// automatically. Signature mismatches are surfaced without restarting.
/// Subset of thane's config.yaml relevant to the macOS app.
/// Parsed on a best-effort basis — always falls back to defaults.
struct LocalThaneConfig {
    var nativePort: Int = 8080
    var ollamaPort: Int = 11434
    var platformEnabled: Bool = false
    var platformToken: String? = nil

    static let defaults = LocalThaneConfig()
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

        var label: String {
            switch self {
            case .notConfigured:    "Not Configured"
            case .stopped:          "Stopped"
            case .starting:         "Starting..."
            case .running:          "Running"
            case .crashed(let c):   "Crashed (exit \(c))"
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
        case stopped   = "Stopped"
    }

    struct ProcessStats {
        var cpuPercent: Double = 0
        var residentMemoryMB: Double = 0
        var threadCount: Int = 0
    }

    // MARK: - Properties

    private(set) var state: State = .notConfigured {
        didSet { onStateChange?(state) }
    }
    private(set) var startedAt: Date?
    private(set) var detectedVersion: String?
    private(set) var localConfig: LocalThaneConfig = .defaults

    /// Called whenever state changes. AppState uses this to auto-connect the WebSocket.
    var onStateChange: ((State) -> Void)?

    /// URL of the thane binary. Set by the user or discovered automatically.
    var binaryURL: URL? {
        didSet {
            UserDefaults.standard.set(binaryURL?.path, forKey: "binaryPath")
            binarySignatureMismatch = false
            refreshState()
            Task { await refreshCodeSignature() }
            startWatchingBinary()
        }
    }

    /// Working directory for the thane process. Thane's config discovery
    /// includes CWD, so ~/Thane/config.yaml is found automatically when
    /// workspaceURL is ~/Thane/. Defaults to ~/Thane/ on first run.
    var workspaceURL: URL {
        didSet {
            UserDefaults.standard.set(workspaceURL.path, forKey: "workspacePath")
        }
    }

    /// Explicit config path. Leave nil to rely on CWD + thane's discovery order.
    var configURL: URL? {
        didSet {
            UserDefaults.standard.set(configURL?.path, forKey: "configPath")
        }
    }

    private(set) var codeSignature: AppleCodeSignature?
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
        case .stopped, .notConfigured:
            return .stopped
        }
    }

    /// True when the last filesystem change produced a signature mismatch.
    /// Surfaced in the UI so the user knows the binary on disk isn't trusted.
    private(set) var binarySignatureMismatch = false

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var restartTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    private var binaryWatcher: DirectoryWatcher?
    private var binaryWatchDebounce: Task<Void, Never>?
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
        if let path = UserDefaults.standard.string(forKey: "configPath") {
            configURL = URL(fileURLWithPath: path)
        }
        refreshState()
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
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try FileManager.default.contentsOfDirectory(atPath: workspace.path)
            } catch {
                logger.error("Workspace is inaccessible at startup: \(workspace.path, privacy: .public); auto-start aborted: \(error.localizedDescription, privacy: .public)")
                append("Auto-start aborted: workspace is inaccessible at \(workspace.path)", isError: true)
                shouldRun = false
                return
            }

            logger.info("Auto-starting local server (shouldRun=true from previous session)")
            start()
        }
    }

    func start() {
        restartTask?.cancel()
        restartTask = nil
        guard let url = binaryURL,
              FileManager.default.fileExists(atPath: url.path),
              !state.isRunning else { return }

        shouldRun = true
        state = .starting
        detectedVersion = nil
        lastCPUSample = nil
        localConfig = Self.parseConfig(at: configURL ?? workspaceURL.appending(path: "config.yaml"))

        let proc = Process()
        proc.executableURL = url
        proc.currentDirectoryURL = workspaceURL
        var args = ["serve"]
        if let configPath = configURL?.path {
            args += ["--config", configPath]
        }
        proc.arguments = args

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
        restartTask?.cancel()
        restartTask = nil
        guard state.isRunning else { return }
        process?.terminate()
        // State update happens in terminationHandler.
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

    // MARK: - Code Signature

    func refreshCodeSignature() async {
        guard let url = binaryURL else {
            codeSignature = nil
            return
        }
        codeSignature = await AppleCodeSignature.inspect(binaryURL: url)
    }

    // MARK: - Maintenance

    /// Stop the binary, perform an action (e.g. replacing the executable), then
    /// restart if it was previously running. Used by UpdateManager for updates.
    func performMaintenance(_ action: @Sendable () throws -> Void) async throws {
        let wasRunning = state.isRunning
        let previousShouldRun = shouldRun
        if wasRunning { stop() }

        // Wait for process to exit
        var waitIterations = 0
        while state.isRunning && waitIterations < 50 {
            try await Task.sleep(for: .milliseconds(100))
            waitIterations += 1
        }

        try action()

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

    private func evaluateBinaryChange() async {
        guard let url = binaryURL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.info("Binary no longer exists at \(url.path)")
            return
        }

        let previousTeamID = codeSignature?.teamID
        let newSignature = await AppleCodeSignature.inspect(binaryURL: url)

        // Always update the displayed signature
        codeSignature = newSignature

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
        } else {
            recentCrashTimestamps.append(Date())
            let cutoff = Date().addingTimeInterval(-300) // 5-minute window
            recentCrashTimestamps = recentCrashTimestamps.filter { $0 > cutoff }
            recentCrashCount = recentCrashTimestamps.count
            state = .crashed(code: code)
            append("thane exited with code \(code)", isError: true)
            logger.error("thane crashed, exit code \(code)")
        }

        if !clean && shouldRun {
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
            if detectedVersion == nil, let parsed = parseJSONLine(trimmed) {
                detectedVersion = parsed.version
            }
        }
    }

    private struct ParsedLine { let version: String? }

    private func parseJSONLine(_ line: String) -> ParsedLine? {
        guard line.hasPrefix("{"),
              let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = obj["thane_version"] as? String
        else { return nil }
        return ParsedLine(version: version)
    }

    private func refreshState() {
        guard !state.isRunning else { return }
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
                await self?.collectStats(pid: pid)
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
            }
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

    // MARK: - Config Parsing

    /// Parse the subset of thane's config.yaml that the macOS app needs.
    /// Uses a simple line-based approach — no YAML library required.
    static func parseConfig(at url: URL) -> LocalThaneConfig {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return .defaults
        }
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

            case "platform":
                if trimmed == "enabled: true"  { result.platformEnabled = true }
                if trimmed == "enabled: false" { result.platformEnabled = false }
                if trimmed == "tokens:" {
                    inTokensList = true
                } else if inTokensList && trimmed.hasPrefix("- ") {
                    if result.platformToken == nil {
                        result.platformToken = extractYAMLListValue(trimmed)
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
