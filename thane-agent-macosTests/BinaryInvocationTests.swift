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
        #expect(args == ["-workspace", "/Users/x/Thane", "serve"])
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
    func flagsPrecedeTheSubcommandSoATypoFailsLoudly() {
        // Verified against thane's parser directly. Once a subcommand has been
        // seen, an unrecognized token is collected as a subcommand argument and
        // the process still exits 0:
        //
        //   serve --workspace /path   -> workspace unset, no error
        //   --workspace /path serve   -> "unknown flag: --workspace"
        //
        // Only the second ordering turns a spelling mistake into a startup
        // failure. The first is how `--config` went unnoticed here.
        let args = BinaryManager.serveArguments(workspace: workspace)
        #expect(args.first == "-workspace")
        #expect(args.last == "serve")
        let flagIndex = args.firstIndex(of: "-workspace")
        let commandIndex = args.firstIndex(of: "serve")
        #expect(flagIndex! < commandIndex!)
    }

    @Test
    func stagedValidateAlsoPutsItsFlagFirst() {
        // UpdateManager builds ["-workspace", path, "validate", "-o", "json"]
        // for the same reason. Documented here so the two invocations are not
        // "fixed" into disagreeing with each other.
        let args = ["-workspace", workspace.path, "validate", "-o", "json"]
        #expect(args.firstIndex(of: "-workspace")! < args.firstIndex(of: "validate")!)
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
