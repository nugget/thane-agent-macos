import Darwin
import Foundation
import os

/// Launches Thane with `posix_spawn` so inherited listening sockets land
/// at the descriptor numbers the systemd socket-activation contract
/// requires (3 and up), which Foundation's `Process` cannot arrange: it
/// passes non-close-on-exec descriptors through at whatever number they
/// hold in the parent. Everything else about the child's environment is
/// deliberately narrow: close-on-exec by default, so only the standard
/// streams and the named sockets cross into Thane.
nonisolated enum ThaneSpawn {
    private static let log = Logger(subsystem: "info.nugget.thane-agent-macos", category: "binary")

    /// One socket to hand down, by the name Thane will see in
    /// `LISTEN_FDNAMES`.
    struct Inherited: Sendable {
        let name: String
        let descriptor: Int32
    }

    /// The `sd_listen_fds(3)` environment for the given names, in order.
    /// `LISTEN_PID` is omitted: `posix_spawn` cannot know the child's pid
    /// before the environment is fixed, and Thane treats its absence as
    /// "no check" rather than "no handoff".
    static func listenEnvironment(names: [String]) -> [String: String] {
        guard !names.isEmpty else { return [:] }
        return [
            "LISTEN_FDS": String(names.count),
            "LISTEN_FDNAMES": names.joined(separator: ":"),
        ]
    }

    /// Spawns `executable` with `arguments` in `workingDirectory`. stdout and
    /// stderr are connected to the given write descriptors, stdin to
    /// /dev/null, and each inherited socket is placed at 3, 4, ... in the
    /// order given, with the matching `LISTEN_*` variables added to the
    /// environment. Returns the child's pid.
    static func spawn(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String],
        inherited: [Inherited],
        stdout: Int32,
        stderr: Int32
    ) throws -> pid_t {
        // Park the inherited descriptors above the range we are about to
        // populate, so mapping fd 3 onto fd 3's old occupant cannot clobber
        // a socket that still needs moving.
        var parked: [Int32] = []
        for socket in inherited {
            let high = fcntl(socket.descriptor, F_DUPFD_CLOEXEC, 64)
            guard high >= 0 else {
                for fd in parked { close(fd) }
                throw SpawnError.system("dup inherited descriptor", errno)
            }
            parked.append(high)
        }
        defer { for fd in parked { close(fd) } }

        var actions: posix_spawn_file_actions_t?
        _ = posix_spawn_file_actions_init(&actions)
        defer { _ = posix_spawn_file_actions_destroy(&actions) }
        _ = posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        _ = posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        _ = posix_spawn_file_actions_adddup2(&actions, stderr, 2)
        for (index, fd) in parked.enumerated() {
            _ = posix_spawn_file_actions_adddup2(&actions, fd, Int32(3 + index))
        }
        _ = posix_spawn_file_actions_addchdir_np(&actions, workingDirectory.path)

        var attrs: posix_spawnattr_t?
        _ = posix_spawnattr_init(&attrs)
        defer { _ = posix_spawnattr_destroy(&attrs) }
        // Reset every signal disposition and clear the signal mask. Both
        // are inherited across exec, and a supervisor that has SIGTERM
        // blocked or ignored (as a GUI app under a debugger or test runner
        // can) would otherwise hand Thane a child it can never stop.
        _ = posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var all = sigset_t()
        _ = sigfillset(&all)
        _ = posix_spawnattr_setsigdefault(&attrs, &all)
        var none = sigset_t()
        _ = sigemptyset(&none)
        _ = posix_spawnattr_setsigmask(&attrs, &none)

        var env = environment
        for (key, value) in listenEnvironment(names: inherited.map(\.name)) {
            env[key] = value
        }
        let argv = [executable.path] + arguments
        let cArgv = argv.map { strdup($0) } + [nil]
        let cEnv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            cArgv.forEach { free($0) }
            cEnv.forEach { free($0) }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable.path, &actions, &attrs, cArgv, cEnv)
        guard rc == 0 else { throw SpawnError.system("posix_spawn", rc) }
        log.info("spawned \(executable.lastPathComponent, privacy: .public) pid \(pid) with \(inherited.count) inherited listener(s)")
        return pid
    }

    enum SpawnError: Error, LocalizedError {
        case system(String, Int32)

        var errorDescription: String? {
            switch self {
            case .system(let what, let code): "\(what): \(String(cString: strerror(code))) (\(code))"
            }
        }
    }
}

/// A child started by `ThaneSpawn`, with the two things the supervisor
/// needs from Foundation's `Process`: a termination callback carrying the
/// same status shape (exit code, or the signal number when killed), and
/// `terminate()`.
nonisolated final class SpawnedProcess: @unchecked Sendable {
    let processIdentifier: pid_t
    private let source: DispatchSourceProcess
    private let lock = NSLock()
    private var handler: (@Sendable (Int32) -> Void)?
    private var finished = false
    /// Holds this object alive until the child exits, as Foundation keeps a
    /// running `Process` alive: a supervisor that drops its reference must
    /// not silently cancel the exit watch and orphan the callback.
    private var keepAlive: SpawnedProcess?

    init(pid: pid_t, terminationHandler: @escaping @Sendable (Int32) -> Void) {
        processIdentifier = pid
        handler = terminationHandler
        source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        keepAlive = self
        source.setEventHandler { [weak self] in self?.reap(block: true) }
        source.resume()
        // A child that exited before the source was armed will never raise
        // the event: kqueue only reports exits it saw. A fast refusal from
        // Thane is exactly that case, so look once, without blocking, now
        // that the source is live; a race with the event is settled by
        // `finished`.
        reap(block: false)
    }

    /// Sends SIGTERM, the same request `Process.terminate()` makes.
    func terminate() {
        kill(processIdentifier, SIGTERM)
    }

    private func reap(block: Bool) {
        var status: Int32 = 0
        var rc: pid_t
        repeat {
            rc = waitpid(processIdentifier, &status, block ? 0 : WNOHANG)
        } while rc == -1 && errno == EINTR
        guard rc == processIdentifier else {
            // 0 means still running (non-blocking poll); -1/ECHILD means the
            // other path already reaped it. Either way there is nothing to do.
            return
        }
        let code: Int32
        if status & 0x7f == 0 {
            code = (status >> 8) & 0xff
        } else {
            code = status & 0x7f
        }
        lock.lock()
        let h = handler
        handler = nil
        let already = finished
        finished = true
        let selfRef = keepAlive
        keepAlive = nil
        lock.unlock()
        source.cancel()
        if !already { h?(code) }
        withExtendedLifetime(selfRef) {}
    }
}
