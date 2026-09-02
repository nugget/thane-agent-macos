import Foundation

/// The XPC contract between the app and the port broker daemon.
///
/// The broker is a LaunchDaemon the app registers through `SMAppService`.
/// Its plist declares `Sockets` for 443 and 80, so launchd binds them as
/// root at boot and hands the listening descriptors to the daemon on
/// check-in. The daemon's only job is to pass those descriptors to the
/// app, which starts Thane with them under the systemd socket-activation
/// contract Thane speaks (`LISTEN_FDS` / `LISTEN_FDNAMES`). Nothing in
/// this file runs as root; it is the shape both sides compile against.
@objc(ThanePortBrokerProtocol)
nonisolated protocol PortBrokerProtocol {
    /// Returns the listening descriptors keyed by socket name (`https`,
    /// `http`), or a description of why none could be produced. Both may
    /// be non-nil when only some sockets were available.
    func listeners(reply: @escaping @Sendable ([String: FileHandle]?, String?) -> Void)
}

/// Names and requirements shared by the daemon, the app, and the tests.
nonisolated enum PortBrokerContract {
    /// The daemon's Mach service, as declared under `MachServices` in its
    /// plist. The app connects to it with `NSXPCConnection`.
    static let machServiceName = "info.nugget.thane-agent-macos.portbroker"

    /// The daemon's plist inside the app bundle, the name `SMAppService`
    /// registers it by.
    static let plistName = "info.nugget.thane-agent-macos.portbroker.plist"

    /// The socket names in the plist's `Sockets` dictionary, which are also
    /// the names Thane looks for in `LISTEN_FDNAMES`.
    static let httpsSocket = "https"
    static let httpSocket = "http"
    static let socketNames = [httpsSocket, httpSocket]

    /// The app's identity. The daemon refuses XPC clients that do not meet
    /// a code-signing requirement built from these, so a root service
    /// never answers a stranger.
    static let appBundleIdentifier = "info.nugget.thane-agent-macos"
    static let teamIdentifier = "9KR5L363XM"

    /// The code-signing requirement the daemon applies to every connection
    /// before honouring a request: Apple-anchored, this bundle identifier,
    /// this team. Exact-match on both, per the repo's rule for
    /// security-relevant strings.
    static var clientRequirement: String {
        "anchor apple generic and identifier \"\(appBundleIdentifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    /// The XPC interface with the reply's collection classes declared, so
    /// the dictionary of file handles survives the trip.
    static func interface() -> NSXPCInterface {
        let interface = NSXPCInterface(with: PortBrokerProtocol.self)
        // NSXPCInterface wants an NSSet of classes; bridging a Swift set of
        // metatypes needs the NSSet detour.
        let classes = NSSet(array: [NSDictionary.self, NSString.self, FileHandle.self]) as! Set<AnyHashable>
        interface.setClasses(
            classes,
            for: #selector(PortBrokerProtocol.listeners(reply:)),
            argumentIndex: 0,
            ofReply: true
        )
        return interface
    }
}
