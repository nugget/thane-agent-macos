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
}
