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
                scheduleRechecks()
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

    /// Re-reads the status at the delays in `PortBrokerRecheck.delays`,
    /// stopping early once the answer is settled.
    private func scheduleRechecks() {
        recheck?.cancel()
        recheck = Task { @MainActor in
            for delay in PortBrokerRecheck.delays {
                try? await Task.sleep(for: delay)
                if Task.isCancelled { return }
                status = PortBroker.status
                if PortBrokerRecheck.isSettled(status) { return }
            }
        }
    }
}

/// The re-check schedule after the toggle is used, kept as data so it can
/// be tested and tuned without touching the view.
nonisolated enum PortBrokerRecheck {
    /// Background Task Management wrote its record roughly thirty seconds
    /// after registration on the operator's machine; the schedule covers
    /// that with a few early looks for the fast case.
    static let delays: [Duration] = [.seconds(1), .seconds(3), .seconds(10), .seconds(30), .seconds(60)]

    /// A settled status is one no amount of waiting will change without
    /// the operator acting: enabled or not registered. Awaiting approval
    /// and not-found are the states worth polling out of.
    static func isSettled(_ status: SMAppService.Status) -> Bool {
        switch status {
        case .enabled, .notRegistered: true
        case .requiresApproval, .notFound: false
        @unknown default: true
        }
    }
}
