import Foundation
import os

/// Manages a local `thane` binary as a child process.
///
/// Lifecycle: find → start → running → stop/crash → stopped
///
/// The canonical install location is ~/Library/Application Support/Thane/thane.
/// For development, we also probe common PATH locations. Users can always
/// point us at an arbitrary path via the Settings UI.
///
/// Future: download/update from GitHub release assets, auto-restart on crash,
/// SMAppService for Login Item integration.
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

    // MARK: - Log

    struct LogLine: Identifiable {
        let id = UUID()
        let timestamp: Date
        let text: String
        let isError: Bool
        /// Structured log level parsed from JSON output (DEBUG/INFO/WARN/ERROR).
        /// Nil for non-JSON lines (internal app messages).
        let level: String?
    }

    // MARK: - Properties

    private(set) var state: State = .notConfigured {
        didSet { onStateChange?(state) }
    }
    private(set) var logLines: [LogLine] = []
    private(set) var startedAt: Date?
    private(set) var detectedVersion: String?
    private(set) var localConfig: LocalThaneConfig = .defaults

    /// Called whenever state changes. AppState uses this to auto-connect the WebSocket.
    var onStateChange: ((State) -> Void)?

    /// URL of the thane binary. Set by the user or discovered automatically.
    var binaryURL: URL? {
        didSet {
            UserDefaults.standard.set(binaryURL?.path, forKey: "binaryPath")
            refreshState()
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

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var restartTask: Task<Void, Never>?
    private var restartAttempt = 0
    private let maxLogLines = 500
    private let logger = Logger(subsystem: "info.nugget.thane-agent-macos", category: "binary")

    /// Whether the server should be running. Persisted across launches.
    private var shouldRun: Bool {
        get { UserDefaults.standard.bool(forKey: "localServerShouldRun") }
        set { UserDefaults.standard.set(newValue, forKey: "localServerShouldRun") }
    }

    // MARK: - Discovery

    /// Canonical location for managed installs (future: downloaded from GitHub).
    static var applicationSupportURL: URL {
        URL.applicationSupportDirectory.appending(components: "Thane", "thane")
    }

    /// Ordered list of paths to probe during auto-discovery.
    static var searchPaths: [URL] {
        [
            applicationSupportURL,
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
        logLines.removeAll()
        detectedVersion = nil
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

    func clearLog() {
        logLines.removeAll()
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

    // MARK: - Private

    private func handleTermination(code: Int32) {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe = nil
        process = nil
        startedAt = nil

        let clean = (code == 0 || code == SIGTERM)
        if clean {
            state = .stopped
            append("thane stopped", isError: false)
        } else {
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
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let new: [LogLine] = lines.map { line in
            let parsed = parseJSONLine(line)
            if detectedVersion == nil, let v = parsed?.version { detectedVersion = v }
            return LogLine(timestamp: Date(), text: line, isError: isError, level: parsed?.level)
        }
        logLines.append(contentsOf: new)
        if logLines.count > maxLogLines {
            logLines.removeFirst(logLines.count - maxLogLines)
        }
    }

    private struct ParsedLine { let version: String?; let level: String? }

    private func parseJSONLine(_ line: String) -> ParsedLine? {
        guard line.hasPrefix("{"),
              let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return ParsedLine(
            version: obj["thane_version"] as? String,
            level: (obj["level"] as? String)?.uppercased()
        )
    }

    private func refreshState() {
        guard !state.isRunning else { return }
        if let url = binaryURL, FileManager.default.fileExists(atPath: url.path) {
            state = .stopped
        } else {
            state = .notConfigured
        }
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
