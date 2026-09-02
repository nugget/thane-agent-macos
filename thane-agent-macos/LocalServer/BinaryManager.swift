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

/// Holds an explicit restart request until the managed child actually exits.
///
/// Graceful shutdown can include checkpointing and other durable cleanup, so
/// elapsed time is not evidence that the old process is gone. The gate keeps
/// that timing concern out of `BinaryManager`: a running child is signalled,
/// and its termination callback consumes the pending request.
nonisolated struct ProcessRestartGate: Sendable {
    private(set) var isPending = false

    /// Returns true when there is no running process and the caller can start
    /// immediately. Otherwise records work for the termination callback.
    mutating func request(processIsRunning: Bool) -> Bool {
        guard processIsRunning else { return true }
        isPending = true
        return false
    }

    mutating func cancel() {
        isPending = false
    }

    /// Consume the request after termination. Only an intentional, clean stop
    /// with the operator's run intent still set should restart immediately.
    mutating func consumeAfterTermination(isClean: Bool, shouldRun: Bool) -> Bool {
        defer { isPending = false }
        return isPending && isClean && shouldRun
    }
}

/// Monotonic deadline for waiting on managed-process shutdown.
nonisolated struct ProcessShutdownDeadline: Sendable {
    private let expiresAt: ContinuousClock.Instant

    init(startedAt: ContinuousClock.Instant, timeout: Duration) {
        expiresAt = startedAt.advanced(by: timeout)
    }

    func hasExpired(at instant: ContinuousClock.Instant) -> Bool {
        instant >= expiresAt
    }
}

nonisolated enum BinaryMaintenanceError: LocalizedError {
    case shutdownTimedOut

    var errorDescription: String? {
        switch self {
        case .shutdownTimedOut:
            "Thane did not stop within 60 seconds. The update was cancelled without replacing the running binary."
        }
    }
}

@Observable
@MainActor
final class BinaryManager {

    // MARK: - State

    nonisolated private static let maxPendingLogCharacters = 65_536
    nonisolated private static let maintenanceShutdownTimeout: Duration = .seconds(60)

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

    nonisolated enum RuntimeLogLevel: String, CaseIterable, Identifiable, Sendable {
        case trace
        case debug
        case info
        case warn
        case error

        var id: String { rawValue }

        var title: String {
            switch self {
            case .trace: "Trace"
            case .debug: "Debug"
            case .info: "Info"
            case .warn: "Warnings"
            case .error: "Errors"
            }
        }

        private var severity: Int {
            switch self {
            case .trace: 0
            case .debug: 1
            case .info: 2
            case .warn: 3
            case .error: 4
            }
        }

        func includes(_ candidate: RuntimeLogLevel) -> Bool {
            candidate.severity >= severity
        }

        static func parse(from line: String) -> RuntimeLogLevel? {
            if line.hasPrefix("{"),
               let data = line.data(using: .utf8),
               let envelope = try? JSONDecoder().decode(StructuredLogEnvelope.self, from: data),
               let level = envelope.level {
                return parse(name: level)
            }

            guard let token = line.split(separator: " ").first(where: {
                $0.lowercased().hasPrefix("level=")
            }) else {
                return nil
            }
            let name = token.dropFirst("level=".count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return parse(name: name)
        }

        static func parse(name: String) -> RuntimeLogLevel? {
            switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "trace", "debug-4": .trace
            case "debug": .debug
            case "info": .info
            case "warn", "warning": .warn
            case "error": .error
            default: nil
            }
        }

        private struct StructuredLogEnvelope: Decodable {
            let level: String?
        }
    }

    nonisolated struct RuntimeLogField: Identifiable, Equatable, Sendable {
        let key: String
        let value: String

        var id: String { key }

        var label: String {
            key.replacingOccurrences(of: "_", with: " ")
        }
    }

    nonisolated struct RuntimeLogPresentation: Equatable, Sendable {
        static let maxMessageLength = 2_000
        static let maxMetadataFields = 12
        static let maxMetadataKeyLength = 80
        static let maxSourceLength = 300

        let date: Date?
        let level: RuntimeLogLevel?
        let message: String
        let source: String?
        let fields: [RuntimeLogField]

        static func parse(from line: String) -> RuntimeLogPresentation? {
            guard line.hasPrefix("{"),
                  let data = line.data(using: .utf8),
                  let values = try? JSONDecoder().decode([String: JSONLogValue].self, from: data),
                  let message = values["msg"]?.stringValue
            else {
                return nil
            }

            let suppressedKeys: Set<String> = [
                "time",
                "level",
                "msg",
                "source",
                "thane_version",
                "thane_commit",
            ]
            let fields = values
                .filter { !suppressedKeys.contains($0.key) }
                .map {
                    RuntimeLogField(
                        key: bounded($0.key, maxLength: maxMetadataKeyLength),
                        value: $0.value.displayValue(maxLength: 160)
                    )
                }
                .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }

            return RuntimeLogPresentation(
                date: values["time"]?.stringValue.flatMap(parseTimestamp),
                level: values["level"]?.stringValue.flatMap(RuntimeLogLevel.parse(name:)),
                message: bounded(message, maxLength: maxMessageLength),
                source: values["source"]?.sourceValue.map {
                    bounded($0, maxLength: maxSourceLength)
                },
                fields: Array(fields.prefix(maxMetadataFields))
            )
        }

        static func bounded(_ value: String, maxLength: Int) -> String {
            guard value.count > maxLength else { return value }
            return String(value.prefix(maxLength - 1)) + "…"
        }

        private static func parseTimestamp(_ value: String) -> Date? {
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value) {
                return date
            }
            return try? Date.ISO8601FormatStyle().parse(value)
        }
    }

    nonisolated struct RuntimeLogEntry: Identifiable, Sendable {
        let id = UUID()
        let date: Date
        let message: String
        let level: RuntimeLogLevel
        let source: String?
        let fields: [RuntimeLogField]

        var isError: Bool { level == .error }
    }

    nonisolated struct RuntimeLogBuffer: Sendable {
        static let defaultCapacity = 250

        private(set) var capacity: Int
        private var storage: [RuntimeLogEntry] = []
        private var nextWriteIndex = 0

        init(capacity: Int = defaultCapacity) {
            precondition(capacity > 0)
            self.capacity = capacity
            storage.reserveCapacity(capacity)
        }

        var isEmpty: Bool { storage.isEmpty }
        var count: Int { storage.count }

        var entries: [RuntimeLogEntry] {
            guard storage.count == capacity, nextWriteIndex != 0 else {
                return storage
            }
            return Array(storage[nextWriteIndex...]) + Array(storage[..<nextWriteIndex])
        }

        mutating func append(_ entry: RuntimeLogEntry) {
            if storage.count < capacity {
                storage.append(entry)
                return
            }
            storage[nextWriteIndex] = entry
            nextWriteIndex = (nextWriteIndex + 1) % capacity
        }

        mutating func removeAll() {
            storage.removeAll(keepingCapacity: true)
            nextWriteIndex = 0
        }
    }

    nonisolated private indirect enum JSONLogValue: Decodable, Sendable {
        case string(String)
        case integer(Int)
        case number(Double)
        case boolean(Bool)
        case object([String: JSONLogValue])
        case array([JSONLogValue])
        case null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode(Bool.self) {
                self = .boolean(value)
            } else if let value = try? container.decode(Int.self) {
                self = .integer(value)
            } else if let value = try? container.decode(Double.self) {
                self = .number(value)
            } else if let value = try? container.decode([String: JSONLogValue].self) {
                self = .object(value)
            } else if let value = try? container.decode([JSONLogValue].self) {
                self = .array(value)
            } else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unsupported JSON log value"
                )
            }
        }

        var stringValue: String? {
            guard case .string(let value) = self else { return nil }
            return value
        }

        var sourceValue: String? {
            switch self {
            case .string(let value):
                return value
            case .object(let values):
                guard let file = values["file"]?.stringValue else { return nil }
                if case .integer(let line)? = values["line"] {
                    return "\(file):\(line)"
                }
                return file
            default:
                return nil
            }
        }

        func displayValue(maxLength: Int) -> String {
            let value: String
            switch self {
            case .string(let string):
                value = string
            case .integer(let integer):
                value = String(integer)
            case .number(let number):
                value = number.formatted(.number.precision(.fractionLength(0...3)))
            case .boolean(let boolean):
                value = boolean ? "true" : "false"
            case .object(let object):
                value = object
                    .map { "\($0.key): \($0.value.displayValue(maxLength: maxLength))" }
                    .sorted()
                    .joined(separator: ", ")
            case .array(let array):
                value = array
                    .map { $0.displayValue(maxLength: maxLength) }
                    .joined(separator: ", ")
            case .null:
                value = "null"
            }

            guard value.count > maxLength else { return value }
            return String(value.prefix(maxLength - 1)) + "…"
        }
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
    private(set) var recentLogs = RuntimeLogBuffer()

    /// Called whenever state changes. AppState uses this to auto-connect the WebSocket.
    var onStateChange: ((State) -> Void)?
    /// Called after a parsed entry enters the bounded runtime log buffer.
    var onLogEntry: ((RuntimeLogEntry) -> Void)?

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

    private var process: SpawnedProcess?

    /// What the port broker contributed to the current or last launch, for
    /// Process Health: inherited privileged ports, or why Thane is binding
    /// its own.
    private(set) var portBrokerSummary = PortBrokerSummary.notEnabled

    nonisolated enum PortBrokerSummary: Equatable, Sendable {
        /// Never registered: the operator has not asked for it.
        case notEnabled
        /// Registered, waiting on the one-time approval in System Settings.
        case requiresApproval
        /// Registered once, but the daemon is no longer in the bundle.
        case notFound
        /// Every expected socket arrived and Thane serves on them.
        case inherited(names: [String])
        /// Some sockets arrived; the missing ones bind from config, and the
        /// daemon's own explanation is kept.
        case partial(names: [String], missing: [String], detail: String)
        /// The daemon was expected and could not deliver.
        case fallback(String)

        var detail: String {
            switch self {
            case .notEnabled:
                "Not enabled; Thane binds the ports in its config. Enable the port broker in Settings to let launchd hold 443 and 80."
            case .requiresApproval:
                "Registered but not yet approved: allow it under System Settings → General → Login Items & Extensions. Until then Thane binds the ports in its config."
            case .notFound:
                "Registered, but the daemon is missing from this app bundle; re-register from Settings. Thane binds the ports in its config."
            case .inherited(let names):
                "launchd holds \(names.joined(separator: " and ")); Thane serves on the inherited sockets."
            case .partial(let names, let missing, let detail):
                "launchd handed over \(names.joined(separator: " and ")) but not \(missing.joined(separator: " and ")) (\(detail)); Thane binds the missing ports from its config."
            case .fallback(let why):
                "\(why) Thane binds the ports in its config instead."
            }
        }

        var isHealthy: Bool {
            switch self {
            case .notEnabled, .inherited: true
            case .requiresApproval, .notFound, .partial, .fallback: false
            }
        }
    }
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutRemainder = ""
    private var stderrRemainder = ""
    private var startTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    private var binaryWatcher: DirectoryWatcher?
    private var binaryWatchDebounce: Task<Void, Never>?
    private var lastKnownBinaryMtime: Date?
    private var isPerformingMaintenance = false
    private var processRestartGate = ProcessRestartGate()
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
                append("Auto-start aborted: workspace is inaccessible at \(workspace.path)", level: .error)
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
                    let workingDirectory = ThaneInvocation.commandWorkingDirectory(for: workspace)
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
                append(lastTerminalMessage ?? "Validation failed", level: .error)
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
                append("Startup blocked: \(report.operatorSummary)", level: .error)
                logger.error("Core preflight failed; refusing to start local thane (exit \(outcome.exitCode))")
                return
            }
            append("Signed core verified", level: .info)
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
        append(lastTerminalMessage ?? "Signed-core validation was unavailable", level: .error)
        logger.error("Thane did not emit a structured integrity report; refusing to start")
    }

    private func launchServe(binaryURL: URL) {
        guard shouldRun, state == .starting else { return }
        // Ask the port broker for launchd's sockets first. The daemon only
        // answers when the operator registered and approved it; otherwise
        // Thane binds its own ports and Process Health says why.
        let registration = PortBroker.registration
        startTask = Task { [weak self] in
            var inherited: [ThaneSpawn.Inherited] = []
            var summary: PortBrokerSummary
            var handles: [String: FileHandle] = [:]
            switch registration {
            case .notRegistered:
                summary = .notEnabled
            case .requiresApproval:
                summary = .requiresApproval
            case .notFound:
                summary = .notFound
            case .enabled:
                do {
                    let result = try await PortBroker.fetchListeners()
                    handles = result.handles
                    let names = PortBrokerContract.socketNames.filter { handles[$0] != nil }
                    let missing = PortBrokerContract.socketNames.filter { handles[$0] == nil }
                    inherited = names.map { ThaneSpawn.Inherited(name: $0, descriptor: handles[$0]!.fileDescriptor) }
                    if names.isEmpty {
                        summary = .fallback("The port broker answered but had no sockets: \(result.detail ?? "no detail").")
                    } else if !missing.isEmpty {
                        summary = .partial(names: names, missing: missing, detail: result.detail ?? "no detail")
                    } else {
                        summary = .inherited(names: names)
                    }
                } catch {
                    summary = .fallback("The port broker could not be reached: \(error.localizedDescription).")
                }
            }
            guard let self, !Task.isCancelled, shouldRun, state == .starting else { return }
            portBrokerSummary = summary
            spawnServe(binaryURL: binaryURL, inherited: inherited, keepAlive: handles)
        }
    }

    /// Starts the serve process. `keepAlive` holds the broker's file handles
    /// until the spawn has duplicated them into the child.
    private func spawnServe(binaryURL: URL, inherited: [ThaneSpawn.Inherited], keepAlive: [String: FileHandle]) {
        guard shouldRun, state == .starting else { return }
        let out = Pipe()
        let err = Pipe()
        stdoutPipe = out
        stderrPipe = err
        stdoutRemainder.removeAll(keepingCapacity: true)
        stderrRemainder.removeAll(keepingCapacity: true)

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in self?.ingestProcessOutput(text, stream: .stdout) }
        }

        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in self?.ingestProcessOutput(text, stream: .stderr) }
        }

        do {
            let pid = try ThaneSpawn.spawn(
                executable: binaryURL,
                arguments: ThaneInvocation.serveArguments(workspace: workspaceURL),
                workingDirectory: workspaceURL,
                environment: ProcessInfo.processInfo.environment,
                inherited: inherited,
                stdout: out.fileHandleForWriting.fileDescriptor,
                stderr: err.fileHandleForWriting.fileDescriptor
            )
            // The child holds its own copies now; the parent's ends of the
            // stdio pipes and the broker's handles are no longer needed.
            try? out.fileHandleForWriting.close()
            try? err.fileHandleForWriting.close()
            withExtendedLifetime(keepAlive) {}
            let proc = SpawnedProcess(pid: pid) { [weak self] code in
                Task { @MainActor [weak self] in self?.handleTermination(code: code) }
            }
            process = proc
            startedAt = Date()
            restartAttempt = 0
            state = .running(pid: pid)
            startStatsPolling(pid: pid)
            switch portBrokerSummary {
            case .inherited(let names):
                append("thane started (pid \(pid)) with inherited \(names.joined(separator: ", ")) sockets from the port broker", level: .info)
            case .partial(let names, let missing, _):
                append("thane started (pid \(pid)) with inherited \(names.joined(separator: ", ")) from the port broker; \(missing.joined(separator: ", ")) not supplied", level: .warn)
            default:
                append("thane started (pid \(pid))", level: .info)
            }
            logger.info("thane started, pid \(pid)")
        } catch {
            state = .stopped
            append("Failed to start: \(error.localizedDescription)", level: .error)
            logger.error("Failed to start thane: \(error.localizedDescription)")
        }
    }

    func stop() {
        processRestartGate.cancel()
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
        processRestartGate.cancel()
        startTask?.cancel()
        restartTask?.cancel()
        statsTask?.cancel()
        process?.terminate()
    }

    func restart() {
        if processRestartGate.request(processIsRunning: state.isRunning) {
            start()
            return
        }

        // Preserve the operator's run intent while graceful shutdown finishes.
        // handleTermination starts the replacement only after the old process
        // has actually exited, however long its checkpoint and cleanup take.
        shouldRun = true
        restartTask?.cancel()
        restartTask = nil
        append("Stopping thane before restart…", level: .info)
        process?.terminate()
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
        append("Initializing the signed workspace…", level: .info)

        let workspace = workspaceURL
        startTask = Task { [weak self] in
            do {
                let outcome = try await Task.detached(priority: .userInitiated) {
                    try ThaneProcessRunner.run(
                        executable: binaryURL,
                        arguments: ThaneInvocation.initializationArguments(workspace: workspace),
                        workingDirectory: ThaneInvocation.commandWorkingDirectory(for: workspace)
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
                    append(lastTerminalMessage ?? "Workspace initialization failed", level: .error)
                    return
                }

                append("Workspace initialized", level: .info)
                state = .stopped
                startTask = nil
                start()
            } catch {
                guard let self, !Task.isCancelled else { return }
                shouldRun = false
                state = .crashed(code: 1)
                lastTerminalMessage = "Could not initialize this workspace: \(error.localizedDescription)"
                append(lastTerminalMessage ?? "Workspace initialization failed", level: .error)
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

        // Never replace the executable while its supervised process is still
        // shutting down. Allow normal durable cleanup substantially longer
        // than the old five-second cap, but abort instead of wedging the
        // updater forever if the child ignores SIGTERM or deadlocks.
        let clock = ContinuousClock()
        let deadline = ProcessShutdownDeadline(
            startedAt: clock.now,
            timeout: Self.maintenanceShutdownTimeout
        )
        do {
            while state.isRunning {
                if deadline.hasExpired(at: clock.now) {
                    throw BinaryMaintenanceError.shutdownTimedOut
                }
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            // The install action has not run, so timeout or cancellation must
            // restore the prior run intent. If shutdown completes later, the
            // normal termination callback starts the unchanged binary.
            if previousShouldRun {
                if state.isRunning {
                    restart()
                } else {
                    start()
                }
            }
            throw error
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
        flushProcessOutputRemainders()

        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe = nil
        process = nil
        startedAt = nil

        let clean = (code == 0 || code == SIGTERM)
        let restartImmediately = processRestartGate.consumeAfterTermination(
            isClean: clean,
            shouldRun: shouldRun
        )
        if clean {
            recentCrashTimestamps.removeAll()
            recentCrashCount = 0
            state = .stopped
            append("thane stopped", level: .info)
        } else if code == ThaneInvocation.terminalExitCode {
            shouldRun = false
            state = .needsAttention(code: code)
            let diagnostic = recentLogs.entries
                .filter(\.isError)
                .suffix(16)
                .map(\.message)
                .joined(separator: "\n")
            if !diagnostic.isEmpty {
                lastTerminalMessage = diagnostic
            }
            append("Thane requires operator attention and will not be restarted automatically", level: .error)
            logger.error("thane exited with terminal code \(code); automatic restart disabled")
        } else {
            recentCrashTimestamps.append(Date())
            pruneStaleCrashes()
            state = .crashed(code: code)
            append("thane exited with code \(code)", level: .error)
            logger.error("thane crashed, exit code \(code)")
        }

        if restartImmediately {
            logger.info("Managed process stopped; starting the requested replacement")
            start()
        } else if !clean && code != ThaneInvocation.terminalExitCode && shouldRun {
            scheduleRestart()
        }
    }

    private func scheduleRestart() {
        restartAttempt += 1
        // Exponential backoff: 2, 4, 8, 16, 32, 60 seconds (capped).
        let delay = min(Double(1 << min(restartAttempt, 6)), 60.0)
        append("Restarting in \(Int(delay))s (attempt \(restartAttempt))…", level: .info)
        logger.info("Scheduling restart in \(delay)s (attempt \(self.restartAttempt))")

        restartTask = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard shouldRun else { return }
            start()
        }
    }

    private func append(_ text: String, level fallbackLevel: RuntimeLogLevel) {
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let presentation = RuntimeLogPresentation.parse(from: trimmed)
            let level = presentation?.level ?? RuntimeLogLevel.parse(from: trimmed) ?? fallbackLevel
            switch level {
            case .trace, .debug:
                logger.debug("\(trimmed, privacy: .public)")
            case .info:
                logger.info("\(trimmed, privacy: .public)")
            case .warn:
                logger.warning("\(trimmed, privacy: .public)")
            case .error:
                logger.error("\(trimmed, privacy: .public)")
            }
            let entry = RuntimeLogEntry(
                date: presentation?.date ?? Date(),
                message: presentation?.message ?? RuntimeLogPresentation.bounded(
                    trimmed,
                    maxLength: RuntimeLogPresentation.maxMessageLength
                ),
                level: level,
                source: presentation?.source,
                fields: presentation?.fields ?? []
            )
            recentLogs.append(entry)
            onLogEntry?(entry)
            if detectedVersion == nil, let parsed = parseJSONLine(trimmed) {
                detectedVersion = parsed.version
                checkVersionCompatibility()
            }
        }
    }

    private enum ProcessLogStream {
        case stdout
        case stderr

        var fallbackLevel: RuntimeLogLevel {
            switch self {
            case .stdout: .info
            case .stderr: .error
            }
        }
    }

    private func ingestProcessOutput(_ chunk: String, stream: ProcessLogStream) {
        let lines: [String]
        switch stream {
        case .stdout:
            lines = Self.extractCompleteLogLines(buffer: &stdoutRemainder, appending: chunk)
        case .stderr:
            lines = Self.extractCompleteLogLines(buffer: &stderrRemainder, appending: chunk)
        }
        for line in lines {
            append(line, level: stream.fallbackLevel)
        }
    }

    private func flushProcessOutputRemainders() {
        if !stdoutRemainder.isEmpty {
            append(stdoutRemainder, level: .info)
            stdoutRemainder.removeAll(keepingCapacity: true)
        }
        if !stderrRemainder.isEmpty {
            append(stderrRemainder, level: .error)
            stderrRemainder.removeAll(keepingCapacity: true)
        }
    }

    nonisolated static func extractCompleteLogLines(
        buffer: inout String,
        appending chunk: String
    ) -> [String] {
        let combined = buffer + chunk
        var parts = combined.split(separator: "\n", omittingEmptySubsequences: false)
        if combined.hasSuffix("\n") {
            buffer.removeAll(keepingCapacity: true)
            if parts.last?.isEmpty == true {
                parts.removeLast()
            }
            return parts.map {
                RuntimeLogPresentation.bounded(
                    String($0),
                    maxLength: maxPendingLogCharacters
                )
            }
        }

        buffer = parts.popLast().map(String.init) ?? ""
        var completeLines = parts.map {
            RuntimeLogPresentation.bounded(
                String($0),
                maxLength: maxPendingLogCharacters
            )
        }
        if buffer.count > maxPendingLogCharacters {
            completeLines.append(
                RuntimeLogPresentation.bounded(buffer, maxLength: maxPendingLogCharacters)
            )
            buffer.removeAll(keepingCapacity: true)
        }
        return completeLines
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
