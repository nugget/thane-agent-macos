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
    }

    // MARK: - Properties

    private(set) var state: State = .notConfigured
    private(set) var logLines: [LogLine] = []

    /// URL of the thane binary. Set by the user or discovered automatically.
    var binaryURL: URL? {
        didSet {
            UserDefaults.standard.set(binaryURL?.path, forKey: "binaryPath")
            refreshState()
        }
    }

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private let maxLogLines = 500
    private let logger = Logger(subsystem: "info.nugget.thane-agent-macos", category: "binary")

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
                FileManager.default.isExecutableFile(atPath: $0.path)
            }
        }
        refreshState()
    }

    // MARK: - Lifecycle

    func start() {
        guard let url = binaryURL,
              FileManager.default.isExecutableFile(atPath: url.path),
              !state.isRunning else { return }

        state = .starting
        logLines.removeAll()

        let proc = Process()
        proc.executableURL = url
        proc.arguments = ["serve"]

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

    // MARK: - Private

    private func handleTermination(code: Int32) {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe = nil
        process = nil

        if code == 0 || code == SIGTERM {
            state = .stopped
            append("thane stopped", isError: false)
        } else {
            state = .crashed(code: code)
            append("thane exited with code \(code)", isError: true)
            logger.error("thane crashed, exit code \(code)")
        }
    }

    private func append(_ text: String, isError: Bool) {
        let new = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { LogLine(timestamp: Date(), text: $0, isError: isError) }
        logLines.append(contentsOf: new)
        if logLines.count > maxLogLines {
            logLines.removeFirst(logLines.count - maxLogLines)
        }
    }

    private func refreshState() {
        guard !state.isRunning else { return }
        if let url = binaryURL, FileManager.default.isExecutableFile(atPath: url.path) {
            state = .stopped
        } else {
            state = .notConfigured
        }
    }
}
