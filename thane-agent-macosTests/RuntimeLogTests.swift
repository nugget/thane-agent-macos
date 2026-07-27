import Foundation
import Testing
@testable import thane_agent_macos

struct RuntimeLogTests {
    struct LevelCase: Sendable {
        let line: String
        let expected: BinaryManager.RuntimeLogLevel
    }

    static let levelCases: [LevelCase] = [
        LevelCase(line: #"{"level":"TRACE","msg":"wire payload"}"#, expected: .trace),
        LevelCase(line: "time=2026-07-26T22:00:00Z level=DEBUG msg=\"details\"", expected: .debug),
        LevelCase(line: "time=2026-07-26T22:00:00Z level=INFO msg=\"ready\"", expected: .info),
        LevelCase(line: "time=2026-07-26T22:00:00Z level=WARN msg=\"slow\"", expected: .warn),
        LevelCase(line: #"{"level":"ERROR","msg":"failed"}"#, expected: .error),
    ]

    @Test(arguments: Self.levelCases)
    func parsesSlogLevels(_ testCase: LevelCase) {
        #expect(BinaryManager.RuntimeLogLevel.parse(from: testCase.line) == testCase.expected)
    }

    @Test
    func parsesStructuredPresentationAndStripsCentralProvenance() {
        let line = """
        {
          "time": "2026-07-26T22:00:00.123Z",
          "level": "DEBUG",
          "source": {
            "function": "info.nugget/thane/internal/app.(*App).Serve",
            "file": "internal/app/serve.go",
            "line": 42
          },
          "msg": "request completed",
          "thane_version": "v0.12.0",
          "thane_commit": "abcdef0",
          "cached": false,
          "duration_ms": 12.25,
          "request_id": "req-123"
        }
        """

        guard let presentation = BinaryManager.RuntimeLogPresentation.parse(from: line) else {
            Issue.record("Expected structured slog JSON to parse")
            return
        }

        #expect(presentation.date != nil)
        #expect(presentation.level == .debug)
        #expect(presentation.message == "request completed")
        #expect(presentation.source == "internal/app/serve.go:42")
        #expect(presentation.fields.map(\.key) == ["cached", "duration_ms", "request_id"])
        #expect(presentation.fields.first(where: { $0.key == "request_id" })?.value == "req-123")
        #expect(!presentation.fields.contains(where: { $0.key == "thane_version" }))
        #expect(!presentation.fields.contains(where: { $0.key == "thane_commit" }))
    }

    @Test
    func malformedOrPlainTextDoesNotPretendToBeStructured() {
        #expect(BinaryManager.RuntimeLogPresentation.parse(from: "not JSON") == nil)
        #expect(BinaryManager.RuntimeLogPresentation.parse(from: #"{"level":"INFO"}"#) == nil)
    }

    @Test
    func minimumLevelIncludesOnlyEqualOrMoreSevereEntries() {
        #expect(BinaryManager.RuntimeLogLevel.warn.includes(.warn))
        #expect(BinaryManager.RuntimeLogLevel.warn.includes(.error))
        #expect(!BinaryManager.RuntimeLogLevel.warn.includes(.info))
        #expect(BinaryManager.RuntimeLogLevel.trace.includes(.debug))
    }

    @Test
    func rollingBufferOverwritesOldestEntriesAtFixedCapacity() {
        var buffer = BinaryManager.RuntimeLogBuffer(capacity: 3)

        for index in 1...5 {
            buffer.append(
                BinaryManager.RuntimeLogEntry(
                    date: Date(timeIntervalSince1970: TimeInterval(index)),
                    message: "entry \(index)",
                    level: .info,
                    source: nil,
                    fields: []
                )
            )
        }

        #expect(buffer.capacity == 3)
        #expect(buffer.count == 3)
        #expect(buffer.entries.map(\.message) == ["entry 3", "entry 4", "entry 5"])

        buffer.removeAll()
        #expect(buffer.isEmpty)
        #expect(buffer.entries.isEmpty)
    }

    @Test
    func processChunksAreFramedIntoCompleteLines() {
        var remainder = ""

        let first = BinaryManager.extractCompleteLogLines(
            buffer: &remainder,
            appending: #"{"level":"WARN","msg":"part"#
        )
        #expect(first.isEmpty)
        #expect(!remainder.isEmpty)

        let second = BinaryManager.extractCompleteLogLines(
            buffer: &remainder,
            appending: "ial\"}\n{\"level\":\"INFO\",\"msg\":\"next\""
        )
        #expect(second == [#"{"level":"WARN","msg":"partial"}"#])
        #expect(remainder == #"{"level":"INFO","msg":"next""#)
    }

    @Test
    func unfinishedLineIsBounded() {
        var remainder = ""
        let lines = BinaryManager.extractCompleteLogLines(
            buffer: &remainder,
            appending: String(repeating: "x", count: 70_000)
        )

        #expect(lines.count == 1)
        #expect(lines[0].count == 65_536)
        #expect(lines[0].hasSuffix("…"))
        #expect(remainder.isEmpty)
    }

    @Test
    func completeLineIsBounded() {
        var remainder = ""
        let lines = BinaryManager.extractCompleteLogLines(
            buffer: &remainder,
            appending: String(repeating: "x", count: 70_000) + "\n"
        )

        #expect(lines.count == 1)
        #expect(lines[0].count == 65_536)
        #expect(lines[0].hasSuffix("…"))
        #expect(remainder.isEmpty)
    }
}
