import Foundation
import Testing
@testable import thane_agent_macos

/// The port broker's contract has three testable seams: the strings the
/// daemon and app must agree on, the environment and descriptor layout
/// Thane receives, and the bundle layout `SMAppService` registers from.
struct PortBrokerTests {

    @Test func clientRequirementPinsBundleAndTeam() {
        #expect(PortBrokerContract.clientRequirement ==
            "anchor apple generic and identifier \"info.nugget.thane-agent-macos\" and certificate leaf[subject.OU] = \"9KR5L363XM\"")
        #expect(PortBrokerContract.socketNames == ["https", "http"])
    }

    @Test func listenEnvironmentFollowsTheSystemdContract() {
        #expect(ThaneSpawn.listenEnvironment(names: []).isEmpty)
        let env = ThaneSpawn.listenEnvironment(names: ["https", "http"])
        #expect(env["LISTEN_FDS"] == "2")
        #expect(env["LISTEN_FDNAMES"] == "https:http")
        #expect(env["LISTEN_PID"] == nil, "LISTEN_PID is set by the trampoline from inside the child, not by the environment builder")
        let hop = ThaneSpawn.trampoline(executable: URL(fileURLWithPath: "/opt/thane/bin/thane"), arguments: ["-workspace", "/w", "serve"])
        #expect(hop.executable.path == "/bin/sh")
        #expect(hop.arguments == ["-c", "LISTEN_PID=$$ exec \"$0\" \"$@\"", "/opt/thane/bin/thane", "-workspace", "/w", "serve"])
        let one = ThaneSpawn.listenEnvironment(names: ["https"])
        #expect(one["LISTEN_FDS"] == "1")
        #expect(one["LISTEN_FDNAMES"] == "https")
    }

    /// Spawns a shell with two inherited descriptors and reads back what it
    /// sees: the sockets at exactly 3 and 4, the environment set, and none
    /// of the parent's other descriptors leaked past close-on-exec.
    @Test(.timeLimit(.minutes(1))) func spawnPlacesInheritedDescriptorsAtThreeAndFour() throws {
        var a: [Int32] = [0, 0]
        var b: [Int32] = [0, 0]
        #expect(pipe(&a) == 0)
        #expect(pipe(&b) == 0)
        defer { for fd in a + b { close(fd) } }
        // Something extra the child must not see, parked at a descriptor
        // number the shell will never reach on its own, so its absence in
        // the child proves close-on-exec rather than luck.
        var strayPipe: [Int32] = [0, 0]
        #expect(pipe(&strayPipe) == 0)
        defer { for fd in strayPipe { close(fd) } }
        let canary = fcntl(strayPipe[0], F_DUPFD, 200)
        #expect(canary >= 200)
        defer { close(canary) }
        _ = fcntl(canary, F_SETFD, 0) // explicitly inheritable if the spawn were sloppy

        let out = Pipe()
        let err = Pipe()
        let pid = try ThaneSpawn.spawn(
            executable: URL(fileURLWithPath: "/bin/sh"),
            // No pipeline inside the child: a shell pipe would leave its own
            // descriptors open in the listing and muddy the leak check.
            // Through the trampoline (sockets are handed down), so the
            // child also proves LISTEN_PID names its own pid.
            arguments: ["-c", "[ -p /dev/fd/3 ] && [ -p /dev/fd/4 ] && echo pipes-at-3-and-4; ls /dev/fd; echo \"$LISTEN_FDS|$LISTEN_FDNAMES|$([ \"$LISTEN_PID\" = \"$$\" ] && echo pid-ok)\""],
            workingDirectory: URL(fileURLWithPath: "/"),
            environment: ["PATH": "/usr/bin:/bin"],
            inherited: [
                ThaneSpawn.Inherited(name: "https", descriptor: a[0]),
                ThaneSpawn.Inherited(name: "http", descriptor: b[0]),
            ],
            stdout: out.fileHandleForWriting.fileDescriptor,
            stderr: err.fileHandleForWriting.fileDescriptor
        )
        try out.fileHandleForWriting.close()
        try err.fileHandleForWriting.close()
        var status: Int32 = 0
        #expect(waitpid(pid, &status, 0) == pid)
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.first == "pipes-at-3-and-4", "child output: \(text)")
        let fds = Set(lines.dropFirst().dropLast().flatMap { $0.split(separator: " ") }.compactMap { Int32($0) })
        #expect(fds.isSuperset(of: [0, 1, 2, 3, 4]), "child saw \(fds)")
        // The shell and ls open a few low descriptors of their own while
        // listing; anything in the parent's range crossed the exec, which
        // close-on-exec-by-default forbids. The stray pipe sits well above
        // that in a GUI host, so it is the canary.
        #expect(fds.filter { $0 > 9 }.isEmpty, "descriptors leaked into the child: \(fds)")
        #expect(!fds.contains(canary), "the canary descriptor \(canary) crossed into the child")
        #expect(lines.last == "2|https:http|pid-ok", "environment line: \(lines.last ?? "")")
    }

    @Test(.timeLimit(.minutes(1))) func spawnReportsExitCodeAndSignal() async throws {
        let out = Pipe()
        let err = Pipe()
        let code = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
            do {
                let pid = try ThaneSpawn.spawn(
                    executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "exit 78"],
                    workingDirectory: URL(fileURLWithPath: "/"),
                    environment: [:],
                    inherited: [],
                    stdout: out.fileHandleForWriting.fileDescriptor,
                    stderr: err.fileHandleForWriting.fileDescriptor
                )
                let proc = SpawnedProcess(pid: pid) { continuation.resume(returning: $0) }
                withExtendedLifetime(proc) {}
            } catch {
                continuation.resume(throwing: error)
            }
        }
        #expect(code == 78)

        let signalled = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
            do {
                let pid = try ThaneSpawn.spawn(
                    executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "sleep 30"],
                    workingDirectory: URL(fileURLWithPath: "/"),
                    environment: [:],
                    inherited: [],
                    stdout: out.fileHandleForWriting.fileDescriptor,
                    stderr: err.fileHandleForWriting.fileDescriptor
                )
                let proc = SpawnedProcess(pid: pid) { continuation.resume(returning: $0) }
                proc.terminate()
                withExtendedLifetime(proc) {}
            } catch {
                continuation.resume(throwing: error)
            }
        }
        #expect(signalled == SIGTERM, "SIGTERM should surface as the signal number, as Process.terminationStatus does")
    }

    /// The daemon and its plist must be inside the app bundle where
    /// `SMAppService.daemon(plistName:)` looks, and the plist must say
    /// what the design promises.
    @Test func bundleCarriesTheDaemonAndItsPlist() throws {
        let bundle = Bundle(for: BinaryManager.self)
        let plistURL = bundle.bundleURL.appending(path: "Contents/Library/LaunchDaemons/\(PortBrokerContract.plistName)")
        let daemonURL = bundle.bundleURL.appending(path: "Contents/MacOS/thane-portbroker")
        #expect(FileManager.default.fileExists(atPath: plistURL.path), "plist missing at \(plistURL.path)")
        #expect(FileManager.default.isExecutableFile(atPath: daemonURL.path), "daemon missing at \(daemonURL.path)")

        let data = try Data(contentsOf: plistURL)
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["Label"] as? String == "info.nugget.thane-agent-macos.portbroker")
        #expect(plist["BundleProgram"] as? String == "Contents/MacOS/thane-portbroker")
        #expect((plist["AssociatedBundleIdentifiers"] as? [String]) == [PortBrokerContract.appBundleIdentifier])
        let mach = try #require(plist["MachServices"] as? [String: Any])
        #expect(mach[PortBrokerContract.machServiceName] as? Bool == true)
        let sockets = try #require(plist["Sockets"] as? [String: [String: Any]])
        #expect(sockets["https"]?["SockServiceName"] as? String == "443")
        #expect(sockets["http"]?["SockServiceName"] as? String == "80")
        #expect(Set(sockets.keys) == Set(PortBrokerContract.socketNames))
    }
}
