import Foundation
import Testing
@testable import thane_agent_macos

struct UpdateConfigValidationTests {
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
