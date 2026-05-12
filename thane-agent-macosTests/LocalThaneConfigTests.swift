import Foundation
import Testing
@testable import thane_agent_macos

/// Tests for the line-based YAML subset parser in `LocalThaneConfig`.
///
/// The parser must recognize the canonical `companion:` block (with
/// `providers.<account>.tokens`) so this app can register as a companion
/// provider against production configs without falling back to the
/// "companion not configured" no-op path in `AppState.connectLocal()`.
struct LocalThaneConfigTests {

    // MARK: - Fixtures

    /// Each row is a self-contained scenario: a YAML snippet plus the
    /// fields we assert on. Mirrors how AppState reads the parsed config.
    struct Case: Sendable {
        let name: String
        let yaml: String
        let expectEnabled: Bool
        let expectToken: String?
        /// Whether `AppState.connectLocal()`'s gate
        /// (`companionEnabled && companionToken != nil`) would pass.
        var expectWouldConnect: Bool { expectEnabled && expectToken != nil }
    }

    static let cases: [Case] = [
        Case(
            name: "companion with one provider and one token",
            yaml: """
            listen:
              port: 8080
            companion:
              enabled: true
              providers:
                nugget:
                  tokens:
                  - nugget-secret-token
            """,
            expectEnabled: true,
            expectToken: "nugget-secret-token"
        ),
        Case(
            name: "companion with two providers picks first token discovered",
            yaml: """
            companion:
              enabled: true
              providers:
                aimee:
                  tokens:
                  - pocket-secret-token
                nugget:
                  tokens:
                  - nugget-secret-token
            """,
            expectEnabled: true,
            expectToken: "pocket-secret-token"
        ),
        Case(
            name: "companion enabled but no providers — no token, won't connect",
            yaml: """
            companion:
              enabled: true
            """,
            expectEnabled: true,
            expectToken: nil
        ),
        Case(
            name: "companion enabled with empty provider tokens list — no token",
            yaml: """
            companion:
              enabled: true
              providers:
                nugget:
                  tokens:
            """,
            expectEnabled: true,
            expectToken: nil
        ),
        Case(
            name: "companion disabled — won't connect even with token",
            yaml: """
            companion:
              enabled: false
              providers:
                nugget:
                  tokens:
                  - secret-but-disabled
            """,
            expectEnabled: false,
            // Token still extracted, but companionEnabled gate blocks connection.
            expectToken: "secret-but-disabled"
        ),
        Case(
            name: "no companion block — defaults to disabled",
            yaml: """
            listen:
              port: 8080
            ollama_api:
              port: 11434
            """,
            expectEnabled: false,
            expectToken: nil
        ),
        Case(
            name: "empty config — defaults",
            yaml: "",
            expectEnabled: false,
            expectToken: nil
        ),
    ]

    // MARK: - Table-driven case runner

    @Test(arguments: Self.cases)
    func parseScenario(_ c: Case) {
        let parsed = LocalThaneConfig.parse(yaml: c.yaml)
        #expect(
            parsed.companionEnabled == c.expectEnabled,
            "\(c.name): companionEnabled = \(parsed.companionEnabled), want \(c.expectEnabled)"
        )
        #expect(
            parsed.companionToken == c.expectToken,
            "\(c.name): companionToken = \(parsed.companionToken ?? "nil"), want \(c.expectToken ?? "nil")"
        )
    }

    // MARK: - Targeted assertions on the production-shape regression

    @Test
    func productionCompanionShapeWouldConnect() {
        // The exact shape now deployed in production. Before the parser
        // was updated to recognize `companion:`, this returned
        // (enabled=false, token=nil) and AppState.connectLocal() bailed,
        // leaving the server with zero registered providers.
        let yaml = """
        companion:
          enabled: true
          providers:
            aimee:
              tokens:
              - pocket-secret-token
            nugget:
              tokens:
              - nugget-secret-token
        """
        let parsed = LocalThaneConfig.parse(yaml: yaml)
        #expect(parsed.companionEnabled)
        #expect(parsed.companionToken != nil)
    }

    // MARK: - Unrelated fields still parse

    @Test
    func portsParseAlongsideCompanion() {
        let yaml = """
        listen:
          port: 9090
        ollama_api:
          port: 22222
        companion:
          enabled: true
          providers:
            nugget:
              tokens:
              - t
        """
        let parsed = LocalThaneConfig.parse(yaml: yaml)
        #expect(parsed.nativePort == 9090)
        #expect(parsed.ollamaPort == 22222)
        #expect(parsed.companionEnabled)
        #expect(parsed.companionToken == "t")
    }

    @Test
    func commentsAndBlankLinesAreIgnored() {
        let yaml = """
        # production companion config
        companion:
          enabled: true
          # a comment between fields
          providers:
            nugget:

              tokens:
              - real-token
        """
        let parsed = LocalThaneConfig.parse(yaml: yaml)
        #expect(parsed.companionToken == "real-token")
    }

    @Test
    func quotedTokenValuesAreUnwrapped() {
        let yaml = """
        companion:
          enabled: true
          providers:
            nugget:
              tokens:
              - "quoted-token"
        """
        let parsed = LocalThaneConfig.parse(yaml: yaml)
        #expect(parsed.companionToken == "quoted-token")
    }

    // MARK: - Legacy platform block is no longer recognized

    @Test
    func legacyPlatformBlockIsIgnored() {
        // Old shape from before companion: was the canonical name. The
        // production config has fully migrated, so the parser deliberately
        // does NOT honour it — a stale config will register as
        // "not configured" rather than silently using an old token.
        let yaml = """
        platform:
          enabled: true
          tokens:
          - legacy-token
        """
        let parsed = LocalThaneConfig.parse(yaml: yaml)
        #expect(!parsed.companionEnabled)
        #expect(parsed.companionToken == nil)
    }
}

extension LocalThaneConfigTests.Case: CustomStringConvertible {
    var description: String { name }
}
