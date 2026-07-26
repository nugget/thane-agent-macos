import Foundation
import Testing
@testable import thane_agent_macos

struct UpdateConfigValidationTests {
    /// `validate -o json` when the config parses but core does not verify.
    /// Note `"valid": true` — the field describes the config file alone, and
    /// the integrity verdict rides on the exit code and the integrity object.
    private static let refusedReport = #"""
    {
      "path": "/Users/x/Thane/core/config.yaml",
      "valid": true,
      "integrity": {
        "workspace": "/Users/x/Thane",
        "core_path": "/Users/x/Thane/core",
        "checks": [
          {"name": "core_repository", "status": "pass", "detail": "core is a git repository"},
          {"name": "core_clean", "status": "fail", "detail": "core has uncommitted changes to tracked files", "fix": "git -C /Users/x/Thane/core commit -aS"},
          {"name": "config_signed", "status": "skipped", "detail": "prerequisite failed"}
        ]
      }
    }
    """#

    @Test
    func validFieldDoesNotCoverIntegrity() {
        // The trap this guards: trusting `valid` alone would cut over to a
        // binary that refuses to serve on first start.
        let report = UpdateManager.parseValidateReport(Self.refusedReport)
        #expect(report?.valid == true)
        #expect(report?.integrity?.failures.count == 2)
    }

    @Test
    func skippedChecksCountAsFailures() {
        // A skipped check means the requirement went unverified because a
        // prerequisite failed; thane's boot gate treats that as failure.
        let report = UpdateManager.parseValidateReport(Self.refusedReport)
        let names = report?.integrity?.failures.map(\.name)
        #expect(names == ["core_clean", "config_signed"])
    }

    @Test
    func refusalReasonNamesFailingChecksAndTheirFixes() {
        let report = UpdateManager.parseValidateReport(Self.refusedReport)
        let reason = UpdateManager.refusalReason(report: report, stderr: "")
        #expect(reason.contains("core_clean"))
        #expect(reason.contains("uncommitted changes"))
        #expect(reason.contains("fix: git -C /Users/x/Thane/core commit -aS"))
    }

    @Test
    func refusalReasonFallsBackToStderrWithoutAReport() {
        // Exit 78 also covers failures that print no JSON at all.
        let stderr = "refusing to start: core integrity check failed for /Users/x/Thane/core"
        let reason = UpdateManager.refusalReason(report: nil, stderr: stderr)
        #expect(reason.contains("refusing to start"))
    }

    @Test
    func refusalReasonIsNeverEmpty() {
        let reason = UpdateManager.refusalReason(report: nil, stderr: "")
        #expect(!reason.isEmpty)
        #expect(reason.contains("78"))
    }

    @Test
    func reportWithoutIntegrityStillDecodes() {
        // Binaries older than the integrity report omit the field entirely.
        let json = #"{"path":"/Users/x/Thane/config.yaml","valid":true}"#
        let report = UpdateManager.parseValidateReport(json)
        #expect(report?.valid == true)
        #expect(report?.integrity == nil)
    }

    @Test
    func parsesValidReport() {
        let json = #"{"path":"/Users/x/Thane/config.yaml","valid":true,"summary":{"default_model":"claude","mcp_servers":2}}"#
        let report = UpdateManager.parseValidateReport(json)
        #expect(report?.valid == true)
        #expect(report?.error == nil)
        #expect(report?.path == "/Users/x/Thane/config.yaml")
    }

    @Test
    func parsesInvalidReportWithError() {
        let json = #"{"path":"/Users/x/Thane/config.yaml","valid":false,"error":"curator: unknown key 'curator' (did you mean 'archivist'?)"}"#
        let report = UpdateManager.parseValidateReport(json)
        #expect(report?.valid == false)
        #expect(report?.error == "curator: unknown key 'curator' (did you mean 'archivist'?)")
    }

    @Test
    func returnsNilForUsageText() {
        // A binary that predates the `validate` subcommand prints usage text
        // instead of a JSON report; the gate must treat this as "no report"
        // (fail-open) rather than as an invalid config.
        let usage = "Usage:\n  thane serve\n  thane init [dir]\nunknown command: validate\n"
        #expect(UpdateManager.parseValidateReport(usage) == nil)
    }

    @Test
    func returnsNilForEmptyOrBlankOutput() {
        #expect(UpdateManager.parseValidateReport("") == nil)
        #expect(UpdateManager.parseValidateReport("   \n") == nil)
    }

    @Test
    func decodesReportWithoutOptionalFields() {
        // path and error are optional in the report; valid is always present.
        let report = UpdateManager.parseValidateReport(#"{"valid":true}"#)
        #expect(report?.valid == true)
        #expect(report?.path == nil)
        #expect(report?.error == nil)
    }
}
