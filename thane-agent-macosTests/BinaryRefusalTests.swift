import Foundation
import Testing
@testable import thane_agent_macos

/// Tests for how the app reports a `thane serve` refusal.
///
/// Thane exits 78 (`EX_CONFIG`) when it examines the instance and declines to
/// serve it — an unverified core, an unsigned config, a bad flag. The same
/// input produces the same refusal forever, so the supervisor must stop rather
/// than restart, and must surface thane's own fix instructions instead of an
/// exit code.
struct BinaryRefusalTests {
    /// A refusal as thane prints it. The structured log records go to stdout
    /// today, but one is included here because the summary must anchor on the
    /// human message even when a log line mentions the same phrase.
    private let stderr = [
        "time=2026-07-26T13:30:00Z level=INFO msg=\"starting Thane\" version=1.4.0",
        "time=2026-07-26T13:30:00Z level=ERROR msg=\"refusing to start\" failed_checks=\"[core_clean]\"",
        "refusing to start: core integrity check failed for /Users/x/Thane/core",
        "",
        "  core_clean: core has uncommitted changes to tracked files",
        "    fix: review with: git -C /Users/x/Thane/core diff",
        "",
        "Run 'thane validate' for the full report.",
    ]

    @Test
    func terminalExitCodeMatchesSysexitsEXCONFIG() {
        #expect(BinaryManager.terminalExitCode == 78)
    }

    @Test
    func summaryStartsAtTheRefusalNotTheStartupLog() {
        let summary = BinaryManager.refusalSummary(fromStderr: stderr)
        #expect(summary?.hasPrefix("refusing to start: core integrity check failed") == true)
        #expect(summary?.contains("msg=\"starting Thane\"") == false)
    }

    @Test
    func summaryKeepsCheckNamesAndFixes() {
        let summary = BinaryManager.refusalSummary(fromStderr: stderr)
        // The fix is a git command run outside the app; losing it would leave
        // the operator with a diagnosis and no remedy.
        #expect(summary?.contains("core_clean:") == true)
        #expect(summary?.contains("fix: review with: git -C /Users/x/Thane/core diff") == true)
        #expect(summary?.contains("thane validate") == true)
    }

    @Test
    func summaryPreservesIndentationUnderEachCheck() {
        let summary = BinaryManager.refusalSummary(fromStderr: stderr)
        #expect(summary?.contains("\n  core_clean:") == true)
        #expect(summary?.contains("\n    fix:") == true)
    }

    @Test
    func summaryDropsBlankLines() {
        // Thane separates checks with blank lines; the captured tail also
        // picks up trailing newlines from partial pipe reads.
        let summary = BinaryManager.refusalSummary(fromStderr: stderr)
        #expect(summary?.contains("\n\n") == false)
    }

    @Test
    func summaryFallsBackToTheTailWhenNoMarkerIsPresent() {
        // Exit 78 also covers bad flags and unloadable configs, which print no
        // "refusing to start" line. Showing nothing would be worse than
        // showing whatever thane did say.
        let usage = ["-config was renamed to -insecure-config", "", "Thane loads its config from <workspace>/core/config.yaml"]
        let summary = BinaryManager.refusalSummary(fromStderr: usage)
        #expect(summary?.contains("-config was renamed to -insecure-config") == true)
        #expect(summary?.contains("Thane loads its config") == true)
    }

    @Test
    func summaryIsNilWhenNothingWasCaptured() {
        #expect(BinaryManager.refusalSummary(fromStderr: []) == nil)
        #expect(BinaryManager.refusalSummary(fromStderr: ["", "   ", "\t"]) == nil)
    }

    // BinaryManager is @MainActor, so State and its Equatable conformance are
    // isolated to it.
    @Test @MainActor
    func refusedStateReadsAsNeedingAttentionNotACrash() {
        #expect(BinaryManager.State.refused.label == "Refused to Start")
        #expect(!BinaryManager.State.refused.isRunning)
        // A crash label would imply the app should keep trying, which is
        // exactly what exit 78 asks it not to do.
        #expect(BinaryManager.State.refused != .crashed(code: 78))
    }
}
