import Foundation
import os

// thane-portbroker: the LaunchDaemon that holds ports 443 and 80 for Thane.
//
// launchd binds the sockets declared in this daemon's plist as root before
// this process exists, and hands them over on check-in. This process
// collects them once and gives them to the companion app over XPC, after
// checking the app's code signature. It never reads traffic and has no
// other capability. Thane, started by the app, serves on the descriptors
// under the systemd socket-activation contract.

private let log = Logger(subsystem: "info.nugget.thane-agent-macos", category: "portbroker")

/// Collects the launchd-activated sockets exactly once. launch_activate_socket
/// hands a name's descriptors over a single time per process, so the result
/// is cached for every later request.
struct ActivationFailure: Error {
    let reason: String
}

final class Broker: NSObject, PortBrokerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var cached: [String: FileHandle] = [:]
    private var failures: [String] = []
    private var activated = false

    func listeners(reply: @escaping @Sendable ([String: FileHandle]?, String?) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        if !activated {
            activated = true
            for name in PortBrokerContract.socketNames {
                switch Self.activate(name) {
                case .success(let handle):
                    cached[name] = handle
                    log.info("activated launchd socket \(name, privacy: .public)")
                case .failure(let failure):
                    failures.append("\(name): \(failure.reason)")
                    log.error("could not activate launchd socket \(name, privacy: .public): \(failure.reason, privacy: .public)")
                }
            }
        }
        reply(cached.isEmpty ? nil : cached, failures.isEmpty ? nil : failures.joined(separator: "; "))
    }

    /// Asks launchd for the descriptors behind one `Sockets` entry and
    /// picks the one to hand over. launchd may create one socket per
    /// address family; a dual-stack IPv6 socket serves both, so it wins,
    /// otherwise the IPv4 one does. Descriptors not chosen are closed so
    /// nothing bound is left unaccepted.
    private static func activate(_ name: String) -> Result<FileHandle, ActivationFailure> {
        // launch_activate_socket wants an int** it can point at a malloc'd
        // array; give it a slot to fill and free the array afterwards.
        let slot = UnsafeMutablePointer<UnsafeMutablePointer<Int32>>.allocate(capacity: 1)
        defer { slot.deallocate() }
        var count = 0
        let rc = launch_activate_socket(name, slot, &count)
        guard rc == 0 else {
            return .failure(ActivationFailure(reason: String(cString: strerror(rc))))
        }
        let fds = slot.pointee
        defer { free(fds) }
        guard count > 0 else {
            return .failure(ActivationFailure(reason: "launchd returned no sockets"))
        }
        let all = (0..<count).map { fds[$0] }
        let chosen = choose(all)
        for fd in all where fd != chosen {
            close(fd)
        }
        return .success(FileHandle(fileDescriptor: chosen, closeOnDealloc: false))
    }

    static func choose(_ fds: [Int32]) -> Int32 {
        if fds.count == 1 { return fds[0] }
        var dualStack: Int32?
        var v4: Int32?
        for fd in fds {
            var addr = sockaddr_storage()
            var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let ok = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) == 0 }
            }
            guard ok else { continue }
            switch Int32(addr.ss_family) {
            case AF_INET6:
                var only: Int32 = 1
                var olen = socklen_t(MemoryLayout<Int32>.size)
                if getsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &only, &olen) == 0, only == 0 {
                    dualStack = fd
                }
            case AF_INET:
                v4 = v4 ?? fd
            default:
                break
            }
        }
        return dualStack ?? v4 ?? fds[0]
    }
}

/// Accepts connections only from the companion app, by code-signing
/// requirement checked against the connection's audit token before any
/// method runs.
final class ListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let broker = Broker()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.setCodeSigningRequirement(PortBrokerContract.clientRequirement)
        newConnection.exportedInterface = PortBrokerContract.interface()
        newConnection.exportedObject = broker
        newConnection.resume()
        log.info("accepted a connection from the companion app")
        return true
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: PortBrokerContract.machServiceName)
listener.delegate = delegate
listener.resume()
log.info("port broker listening on \(PortBrokerContract.machServiceName, privacy: .public)")
RunLoop.main.run()
