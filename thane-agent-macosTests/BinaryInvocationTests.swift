import Foundation
import Testing
@testable import thane_agent_macos

/// Tests for the argv the app hands `thane serve`, and for the config path
/// that argv implies.
///
/// Thane parses arguments by hand rather than with the flag package: tokens it
/// does not recognize are collected as subcommand arguments once a subcommand
/// has been seen, so a wrong flag spelling is dropped silently instead of
/// erroring. That failure mode is invisible at runtime — the binary starts and
/// serves the wrong instance — which is why the spelling is asserted here.
struct BinaryInvocationTests {
    private let workspace = URL(fileURLWithPath: "/Users/x/Thane")

    @Test
    func serveNamesTheWorkspaceWithASingleDashFlag() {
        let args = BinaryManager.serveArguments(workspace: workspace)
        #expect(args == ["serve", "-workspace", "/Users/x/Thane"])
    }

    @Test
    func serveNeverPassesAConfigPath() {
        // A config outside core cannot be covered by the instance's signed
        // history, so thane only accepts one via -insecure-config — which
        // skips the startup integrity gate. The app supervises a verified
        // instance and must never opt out of that check.
        let args = BinaryManager.serveArguments(workspace: workspace)
        for flag in ["-config", "--config", "-insecure-config"] {
            #expect(!args.contains(flag), "serve must not pass \(flag)")
        }
    }

    @Test
    func subcommandComesFirstSoFlagsAreNotSwallowed() {
        // Thane treats the first non-flag token as the subcommand; anything
        // unrecognized after that becomes a subcommand argument.
        let args = BinaryManager.serveArguments(workspace: workspace)
        #expect(args.first == "serve")
    }

    @Test
    func coreConfigResolvesUnderTheWorkspace() {
        // Must match config.CoreConfigPath() on the Go side:
        // {workspace.path}/core/config.yaml.
        let resolved = BinaryManager.coreConfigURL(workspace: workspace)
        #expect(resolved.path == "/Users/x/Thane/core/config.yaml")
    }

    @Test
    func coreConfigTracksTheWorkspaceItIsGiven() {
        let elsewhere = URL(fileURLWithPath: "/tmp/instance-b")
        #expect(
            BinaryManager.coreConfigURL(workspace: elsewhere).path
                == "/tmp/instance-b/core/config.yaml"
        )
    }
}
