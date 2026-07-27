import Foundation

/// The command-line contract shared by local process supervision and staged
/// update validation.
///
/// Since thane-ai-agent PR 1260, the workspace selects the canonical signed
/// config at `<workspace>/core/config.yaml`. An arbitrary config path is a
/// recovery-only, explicitly insecure mode and is intentionally not part of
/// the app's normal launch surface.
nonisolated enum ThaneInvocation {
    static let terminalExitCode: Int32 = 78

    static func canonicalConfigURL(workspace: URL) -> URL {
        workspace.appending(components: "core", "config.yaml")
    }

    static func validationArguments(workspace: URL) -> [String] {
        ["-workspace", workspace.path, "-o", "json", "validate"]
    }

    static func serveArguments(workspace: URL) -> [String] {
        ["-workspace", workspace.path, "serve"]
    }

    static func initializationArguments(workspace: URL) -> [String] {
        ["init", workspace.path]
    }
}

/// One requirement in thane's structured core-integrity report.
nonisolated struct CoreIntegrityCheck: Decodable, Equatable, Identifiable, Sendable {
    let name: String
    let status: String
    let detail: String
    let fix: String?

    var id: String { name }
    var passed: Bool { status == "pass" }
}

/// The integrity portion of `thane validate -o json`.
nonisolated struct CoreIntegrityReport: Decodable, Equatable, Sendable {
    let workspace: String
    let corePath: String
    let configPath: String
    let checks: [CoreIntegrityCheck]

    enum CodingKeys: String, CodingKey {
        case workspace
        case corePath = "core_path"
        case configPath = "config_path"
        case checks
    }

    var passed: Bool {
        !checks.isEmpty && checks.allSatisfy(\.passed)
    }

    var failures: [CoreIntegrityCheck] {
        checks.filter { !$0.passed }
    }

    var repairCommands: [String] {
        var seen = Set<String>()
        return failures.compactMap(\.fix).filter { command in
            !command.isEmpty && seen.insert(command).inserted
        }
    }
}

/// The complete structured preflight emitted by `thane validate -o json`.
///
/// `valid` describes config parsing. Core integrity is reported separately, so
/// callers must use `passed` rather than `valid` alone before starting serve.
nonisolated struct ThaneValidationReport: Decodable, Equatable, Sendable {
    let path: String?
    let valid: Bool
    let error: String?
    let integrity: CoreIntegrityReport?

    var passed: Bool {
        valid && integrity?.passed == true
    }

    var operatorSummary: String {
        if let error, !error.isEmpty {
            return error
        }
        if let first = integrity?.failures.first {
            return first.detail
        }
        return passed ? "Configuration and signed core verified." : "Thane could not verify this workspace."
    }

    static func parse(_ stdout: String) -> ThaneValidationReport? {
        guard let data = stdout.data(using: .utf8), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(ThaneValidationReport.self, from: data)
    }
}

/// Captured result from a short-lived thane command.
nonisolated struct ThaneProcessOutcome: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

/// Runs bounded, short-lived thane commands away from the main actor.
nonisolated enum ThaneProcessRunner {
    static func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        ensureExecutable: Bool = false
    ) throws -> ThaneProcessOutcome {
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = workingDirectory
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        if ensureExecutable {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executable.path
            )
        }

        try process.run()

        // Drain both pipes concurrently. Reading either one to EOF first can
        // deadlock if the child fills the other pipe before it exits.
        let errorBox = ProcessOutputBox()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            errorBox.data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        drained.wait()
        process.waitUntilExit()

        return ThaneProcessOutcome(
            exitCode: process.terminationStatus,
            stdout: String(data: outputData, encoding: .utf8) ?? "",
            stderr: String(data: errorBox.data, encoding: .utf8) ?? ""
        )
    }
}

/// Single-writer box used to bridge a pipe drain back from its background
/// queue. The semaphore in `ThaneProcessRunner.run` establishes the
/// happens-before relationship before `data` is read.
nonisolated private final class ProcessOutputBox: @unchecked Sendable {
    var data = Data()
}
