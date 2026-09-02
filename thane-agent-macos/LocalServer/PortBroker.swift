import Foundation
import ServiceManagement
import os

/// The app's side of the port broker: registering the daemon with
/// `SMAppService`, reporting its status, and fetching the launchd-bound
/// descriptors over XPC when Thane starts.
///
/// Registration is the operator's decision, made in Settings and approved
/// once in System Settings under Login Items and Extensions, where the
/// daemon appears under this app's name. Fetching is a bounded XPC call
/// the app makes before each launch; when it fails for any reason Thane
/// starts on its configured high ports and Process Health says so.
nonisolated enum PortBroker {
    private static let log = Logger(subsystem: "info.nugget.thane-agent-macos", category: "portbroker")

    static var service: SMAppService {
        SMAppService.daemon(plistName: PortBrokerContract.plistName)
    }

    static var status: SMAppService.Status { service.status }

    /// True when the daemon is registered and approved, which is the only
    /// state in which asking it for sockets can succeed.
    static var isEnabled: Bool { status == .enabled }

    /// The registration state without the ServiceManagement import, for
    /// the supervisor to report exactly.
    nonisolated enum Registration: Equatable, Sendable {
        case notRegistered
        case requiresApproval
        case enabled
        case notFound
    }

    static var registration: Registration {
        switch status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        case .notRegistered: .notRegistered
        @unknown default: .notRegistered
        }
    }

    static func register() throws {
        try service.register()
        log.info("port broker registered: \(String(describing: service.status), privacy: .public)")
    }

    static func unregister() throws {
        try service.unregister()
        log.info("port broker unregistered")
    }

    /// Asks the daemon for its descriptors. Returns the handles keyed by
    /// socket name, plus any partial-failure text the daemon reported.
    /// Throws when the daemon is unreachable or does not answer in time.
    static func fetchListeners(timeout: Duration = .seconds(4)) async throws -> (handles: [String: FileHandle], detail: String?) {
        try await withThrowingTaskGroup(of: (handles: [String: FileHandle], detail: String?).self) { group in
            group.addTask {
                // The timeout task cancels this one; cancellation must
                // complete the exchange (and invalidate the connection) or
                // the group would wait forever on a daemon that never
                // answers.
                let slot = ExchangeSlot()
                return try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        let connection = NSXPCConnection(machServiceName: PortBrokerContract.machServiceName, options: .privileged)
                        connection.remoteObjectInterface = PortBrokerContract.interface()
                        let exchange = BrokerExchange(continuation: continuation, connection: connection)
                        guard slot.install(exchange) else {
                            // Cancelled before we got here.
                            exchange.finish(throwing: CancellationError())
                            return
                        }
                        connection.invalidationHandler = {
                            exchange.finish(throwing: PortBrokerError.unavailable("the port broker connection was invalidated"))
                        }
                        connection.resume()
                        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                            exchange.finish(throwing: PortBrokerError.unavailable(error.localizedDescription))
                        }
                        guard let broker = proxy as? PortBrokerProtocol else {
                            exchange.finish(throwing: PortBrokerError.unavailable("the port broker proxy has the wrong type"))
                            return
                        }
                        broker.listeners { handles, detail in
                            exchange.finish(returning: (handles ?? [:], detail))
                        }
                    }
                } onCancel: {
                    slot.cancel()
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw PortBrokerError.unavailable("the port broker did not answer within \(timeout)")
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }
}

enum PortBrokerError: Error, LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let why): why
        }
    }
}

/// Hands the in-flight exchange to the cancellation handler, whichever of
/// the two arrives first.
nonisolated private final class ExchangeSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var exchange: BrokerExchange?
    private var cancelled = false

    /// Records the exchange; returns false if cancellation already came.
    func install(_ exchange: BrokerExchange) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if cancelled { return false }
        self.exchange = exchange
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let pending = exchange
        exchange = nil
        lock.unlock()
        pending?.finish(throwing: CancellationError())
    }
}

/// One request to the broker: resumes its continuation at most once,
/// whichever XPC callback fires first (the reply, the error handler, or
/// invalidation), and invalidates the connection when done. The
/// connection is owned here so the callbacks capture only this box.
nonisolated private final class BrokerExchange: @unchecked Sendable {
    typealias Outcome = (handles: [String: FileHandle], detail: String?)

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Outcome, Error>?
    private var connection: NSXPCConnection?

    init(continuation: CheckedContinuation<Outcome, Error>, connection: NSXPCConnection) {
        self.continuation = continuation
        self.connection = connection
    }

    func finish(returning value: Outcome) {
        complete { $0.resume(returning: value) }
    }

    func finish(throwing error: Error) {
        complete { $0.resume(throwing: error) }
    }

    private func complete(_ resume: (CheckedContinuation<Outcome, Error>) -> Void) {
        lock.lock()
        let pending = continuation
        let conn = connection
        continuation = nil
        connection = nil
        lock.unlock()
        if let pending { resume(pending) }
        conn?.invalidate()
    }
}
