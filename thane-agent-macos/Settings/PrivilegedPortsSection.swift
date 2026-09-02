import AppKit
import ServiceManagement
import SwiftUI

/// The managed instance's privileged-port control: registers or removes the
/// port broker daemon and reports where its approval stands.
///
/// It lives with the managed-instance settings because it only means
/// something when this app supervises a Thane binary; a companion pointed
/// at a remote Thane has no ports to hold. Registration status is asked
/// again on a schedule after the toggle is used and whenever the app
/// regains focus, because Background Task Management writes its record
/// some seconds after `register()` returns and the operator approves in
/// System Settings and comes back, so a single read at toggle time is
/// reliably stale.
struct PrivilegedPortsSection: View {
    @State private var status = PortBroker.status
    @State private var error: String?
    @State private var recheck: Task<Void, Never>?

    private var binding: Binding<Bool> {
        Binding(
            get: { status == .enabled || status == .requiresApproval },
            set: { enable in
                do {
                    error = nil
                    if enable {
                        try PortBroker.register()
                    } else {
                        try PortBroker.unregister()
                    }
                } catch {
                    self.error = error.localizedDescription
                }
                status = PortBroker.status
                scheduleRechecks(wanting: enable)
            }
        )
    }

    var body: some View {
        Section {
            Toggle("Hold ports 443 and 80 for Thane", isOn: binding)
            if status == .requiresApproval {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.yellow)
                    Text("Approval required in System Settings → General → Login Items & Extensions, under Allow in the Background.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open…") {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                    .font(.caption)
                }
            }
            if status == .notFound {
                Text("Registered, but the daemon is missing from this app bundle. Turn the toggle off and on to re-register.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Privileged Ports")
        } footer: {
            Text("macOS refuses ports below 1024 to ordinary users. This registers a small daemon under this app's name so launchd binds 443 and 80 at boot and hands them to Thane's HTTPS front door; Thane itself never runs with privilege. Takes effect the next time Thane starts.")
        }
        .onAppear { status = PortBroker.status }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            status = PortBroker.status
        }
        .onDisappear { recheck?.cancel() }
    }

    /// Re-reads the status at the deadlines in `PortBrokerRecheck.deadlines`
    /// (measured from the toggle, so each sleep is only the gap since the
    /// previous look), stopping early once the status has reached what the
    /// toggle asked for.
    private func scheduleRechecks(wanting enabled: Bool) {
        recheck?.cancel()
        recheck = Task { @MainActor in
            for gap in PortBrokerRecheck.intervals {
                try? await Task.sleep(for: gap)
                if Task.isCancelled { return }
                status = PortBroker.status
                if PortBrokerRecheck.isSettled(status, wanting: enabled) { return }
            }
        }
    }
}

/// The re-check schedule after the toggle is used, kept as data so it can
/// be tested and tuned without touching the view.
nonisolated enum PortBrokerRecheck {
    /// Elapsed time after the toggle at which to look again. Background
    /// Task Management wrote its record roughly thirty seconds after
    /// registration on the operator's machine; the schedule covers that
    /// with a few early looks for the fast case.
    static let deadlines: [Duration] = [.seconds(1), .seconds(3), .seconds(10), .seconds(30), .seconds(60)]

    /// The gaps to sleep between looks, so the looks land on the deadlines
    /// rather than on their running sum.
    static var intervals: [Duration] {
        var previous = Duration.zero
        return deadlines.map { deadline in
            defer { previous = deadline }
            return deadline - previous
        }
    }

    /// Whether the status has reached what the toggle asked for. Right after
    /// register() the status can still read not-registered until Background
    /// Task Management writes its record, and right after unregister() it
    /// can still read enabled, so the resting state depends on the request:
    /// enabled when turning on, not registered when turning off. Anything
    /// else is worth another look.
    static func isSettled(_ status: SMAppService.Status, wanting enabled: Bool) -> Bool {
        switch (status, enabled) {
        case (.enabled, true), (.notRegistered, false): true
        default: false
        }
    }
}
