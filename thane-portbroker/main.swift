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

    /// Asks launchd for the descriptors behind one `Sockets` entry. The
    /// plist requests `IPv4v6`, which launchd.plist(5) documents as a
    /// single socket that listens for both families, and Thane's contract
    /// takes one descriptor per name; anything other than exactly one is
    /// therefore a misconfiguration that is reported rather than resolved
    /// by silently dropping a family, and every descriptor is closed so
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
        guard all.count == 1 else {
            for fd in all { close(fd) }
            return .failure(ActivationFailure(reason: "launchd returned \(all.count) sockets; expected the single dual-stack socket SockFamily IPv4v6 declares"))
        }
        return .success(FileHandle(fileDescriptor: all[0], closeOnDealloc: false))
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
