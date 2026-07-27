import Foundation
import Testing
@testable import thane_agent_macos

struct UpdateConfigValidationTests {
    @Test
    func parsesValidReport() {
        let json = """
        {
          "path": "/Users/x/Thane/core/config.yaml",
          "valid": true,
          "summary": {"default_model":"claude","mcp_servers":2},
          "integrity": {
            "workspace": "/Users/x/Thane",
            "core_path": "/Users/x/Thane/core",
            "config_path": "/Users/x/Thane/core/config.yaml",
            "checks": [
              {"name":"core_repository","status":"pass","detail":"ok"}
            ]
          }
        }
        """
        let report = ThaneValidationReport.parse(json)
        #expect(report?.valid == true)
        #expect(report?.passed == true)
        #expect(report?.error == nil)
        #expect(report?.path == "/Users/x/Thane/core/config.yaml")
    }

    @Test
    func parsesInvalidReportWithError() {
        let json = #"{"path":"/Users/x/Thane/core/config.yaml","valid":false,"error":"curator: unknown key 'curator' (did you mean 'archivist'?)"}"#
        let report = ThaneValidationReport.parse(json)
        #expect(report?.valid == false)
        #expect(report?.passed == false)
        #expect(report?.error == "curator: unknown key 'curator' (did you mean 'archivist'?)")
    }

    @Test
    func integrityFailureBlocksOtherwiseValidConfig() {
        let json = """
        {
          "path": "/Users/x/Thane/core/config.yaml",
          "valid": true,
          "integrity": {
            "workspace": "/Users/x/Thane",
            "core_path": "/Users/x/Thane/core",
            "config_path": "/Users/x/Thane/core/config.yaml",
            "checks": [
              {"name":"core_repository","status":"pass","detail":"core is a git repository"},
              {"name":"config_signed","status":"fail","detail":"signature verification failed","fix":"git -C /Users/x/Thane/core commit -S"}
            ]
          }
        }
        """
        let report = ThaneValidationReport.parse(json)
        #expect(report?.valid == true)
        #expect(report?.passed == false)
        #expect(report?.integrity?.failures.map(\.name) == ["config_signed"])
        #expect(report?.integrity?.repairCommands == ["git -C /Users/x/Thane/core commit -S"])
    }

    @Test
    func allIntegrityChecksMustPass() {
        let json = """
        {
          "valid": true,
          "integrity": {
            "workspace": "/Users/x/Thane",
            "core_path": "/Users/x/Thane/core",
            "config_path": "/Users/x/Thane/core/config.yaml",
            "checks": [
              {"name":"core_repository","status":"pass","detail":"ok"},
              {"name":"config_signed","status":"pass","detail":"ok"}
            ]
          }
        }
        """
        #expect(ThaneValidationReport.parse(json)?.passed == true)
    }

    @Test
    func returnsNilForUsageText() {
        // A binary that predates the `validate` subcommand prints usage text
        // instead of a JSON report. Parsing returns nil so the caller can
        // refuse launch or update rather than weakening the trust boundary.
        let usage = "Usage:\n  thane serve\n  thane init [dir]\nunknown command: validate\n"
        #expect(ThaneValidationReport.parse(usage) == nil)
    }

    @Test
    func returnsNilForEmptyOrBlankOutput() {
        #expect(ThaneValidationReport.parse("") == nil)
        #expect(ThaneValidationReport.parse("   \n") == nil)
    }

    @Test
    func decodesReportWithoutOptionalFields() {
        // path and error are optional in the report; valid is always present.
        let report = ThaneValidationReport.parse(#"{"valid":true}"#)
        #expect(report?.valid == true)
        #expect(report?.passed == false)
        #expect(report?.path == nil)
        #expect(report?.error == nil)
    }

    @Test
    func invocationUsesWorkspaceAndGlobalOutputFlags() {
        let workspace = URL(fileURLWithPath: "/Users/x/Thane")
        #expect(ThaneInvocation.canonicalConfigURL(workspace: workspace).path == "/Users/x/Thane/core/config.yaml")
        #expect(ThaneInvocation.validationArguments(workspace: workspace) == [
            "-workspace", "/Users/x/Thane", "-o", "json", "validate",
        ])
        #expect(ThaneInvocation.serveArguments(workspace: workspace) == [
            "-workspace", "/Users/x/Thane", "serve",
        ])
        #expect(ThaneInvocation.initializationArguments(workspace: workspace) == [
            "init", "/Users/x/Thane",
        ])
        #expect(ThaneInvocation.terminalExitCode == 78)
    }

    @Test
    func commandWorkingDirectoryAlwaysSelectsAnExistingDirectory() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(
            path: "ThaneWorkingDirectoryTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let workspace = root.appending(path: "Thane", directoryHint: .isDirectory)
        try fm.createDirectory(at: workspace, withIntermediateDirectories: false)
        #expect(ThaneInvocation.commandWorkingDirectory(for: workspace) == workspace)

        let missingWorkspace = root.appending(path: "FirstRun", directoryHint: .isDirectory)
        #expect(ThaneInvocation.commandWorkingDirectory(for: missingWorkspace) == root)

        let fileWorkspace = root.appending(path: "NotADirectory")
        #expect(fm.createFile(atPath: fileWorkspace.path, contents: Data()))
        #expect(ThaneInvocation.commandWorkingDirectory(for: fileWorkspace) == root)

        let missingParent = root
            .appending(path: "MissingParent", directoryHint: .isDirectory)
            .appending(path: "Thane", directoryHint: .isDirectory)
        #expect(
            ThaneInvocation.commandWorkingDirectory(for: missingParent) == .homeDirectory
        )
    }

    @Test
    func stagedValidationAllowsFirstInstallWithSignedCoreReport() {
        let outcome = ThaneProcessOutcome(
            exitCode: ThaneInvocation.terminalExitCode,
            stdout: """
            {
              "path": "",
              "valid": false,
              "error": "no config found",
              "integrity": {
                "workspace": "/Users/x/Thane",
                "core_path": "/Users/x/Thane/core",
                "config_path": "/Users/x/Thane/core/config.yaml",
                "checks": [
                  {
                    "name": "core_directory",
                    "status": "fail",
                    "detail": "no core directory",
                    "fix": "thane init /Users/x/Thane"
                  }
                ]
              }
            }
            """,
            stderr: ""
        )

        #expect(
            StagedConfigValidationPolicy.evaluate(
                outcome: outcome,
                canonicalConfigExists: false
            ) == .valid
        )
    }

    @Test
    func stagedValidationRejectsLegacyReportOnFirstInstall() {
        let outcome = ThaneProcessOutcome(
            exitCode: 1,
            stdout: #"{"path":"","valid":false,"error":"no config found"}"#,
            stderr: ""
        )

        #expect(
            StagedConfigValidationPolicy.evaluate(
                outcome: outcome,
                canonicalConfigExists: false
            ) == .invalid(reason: StagedConfigValidationPolicy.missingIntegrityReason)
        )
    }

    @Test
    func stagedValidationRejectsInvalidActiveConfigWithOperatorReason() {
        let outcome = ThaneProcessOutcome(
            exitCode: ThaneInvocation.terminalExitCode,
            stdout: """
            {
              "path": "/Users/x/Thane/core/config.yaml",
              "valid": true,
              "integrity": {
                "workspace": "/Users/x/Thane",
                "core_path": "/Users/x/Thane/core",
                "config_path": "/Users/x/Thane/core/config.yaml",
                "checks": [
                  {
                    "name": "config_signed",
                    "status": "fail",
                    "detail": "signature verification failed"
                  }
                ]
              }
            }
            """,
            stderr: ""
        )

        #expect(
            StagedConfigValidationPolicy.evaluate(
                outcome: outcome,
                canonicalConfigExists: true
            ) == .invalid(reason: "signature verification failed")
        )
    }

    @Test
    func stagedValidationAcceptsValidActiveConfig() {
        let outcome = ThaneProcessOutcome(
            exitCode: 0,
            stdout: """
            {
              "path": "/Users/x/Thane/core/config.yaml",
              "valid": true,
              "integrity": {
                "workspace": "/Users/x/Thane",
                "core_path": "/Users/x/Thane/core",
                "config_path": "/Users/x/Thane/core/config.yaml",
                "checks": [
                  {"name": "config_signed", "status": "pass", "detail": "ok"}
                ]
              }
            }
            """,
            stderr: ""
        )

        #expect(
            StagedConfigValidationPolicy.evaluate(
                outcome: outcome,
                canonicalConfigExists: true
            ) == .valid
        )
    }

    @Test
    func stagedValidationRequiresSuccessfulExitForActiveConfig() {
        let outcome = ThaneProcessOutcome(
            exitCode: 1,
            stdout: """
            {
              "path": "/Users/x/Thane/core/config.yaml",
              "valid": true,
              "integrity": {
                "workspace": "/Users/x/Thane",
                "core_path": "/Users/x/Thane/core",
                "config_path": "/Users/x/Thane/core/config.yaml",
                "checks": [
                  {"name": "config_signed", "status": "pass", "detail": "ok"}
                ]
              }
            }
            """,
            stderr: ""
        )

        #expect(
            StagedConfigValidationPolicy.evaluate(
                outcome: outcome,
                canonicalConfigExists: true
            ) == .invalid(
                reason: "The new Thane binary exited with status 1 during validation."
            )
        )
    }
}
