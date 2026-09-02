import ServiceManagement
import Testing
@testable import thane_agent_macos

/// The re-check schedule after the privileged-ports toggle: Background Task
/// Management writes its record seconds after registration returns, so the
/// view keeps looking until the answer is one that waiting cannot change.
struct PortBrokerRecheckTests {

    @Test func deadlinesAreAscendingAndCoverTheObservedLag() {
        let deadlines = PortBrokerRecheck.deadlines
        #expect(deadlines.count >= 3)
        for (a, b) in zip(deadlines, deadlines.dropFirst()) {
            #expect(a < b, "re-check deadlines should grow")
        }
        #expect(deadlines.contains(.seconds(30)), "BTM took about thirty seconds on the operator's machine")
    }

    /// The sleeps between looks must sum to the deadlines, not compound
    /// past them: sleeping each deadline in full would look at 1, 4, 14,
    /// 44, and 104 seconds and miss the thirty-second transition.
    @Test func intervalsLandOnTheDeadlines() {
        var elapsed = Duration.zero
        for (gap, deadline) in zip(PortBrokerRecheck.intervals, PortBrokerRecheck.deadlines) {
            elapsed += gap
            #expect(elapsed == deadline)
        }
        #expect(PortBrokerRecheck.intervals.count == PortBrokerRecheck.deadlines.count)
    }

    @Test func settlementDependsOnWhatTheToggleAskedFor() {
        // Turning on: only enabled ends the polling; a stale not-registered
        // or a pending approval keeps looking.
        #expect(PortBrokerRecheck.isSettled(.enabled, wanting: true))
        #expect(!PortBrokerRecheck.isSettled(.notRegistered, wanting: true))
        #expect(!PortBrokerRecheck.isSettled(.requiresApproval, wanting: true))
        #expect(!PortBrokerRecheck.isSettled(.notFound, wanting: true))
        // Turning off: only not-registered ends it; a stale enabled keeps looking.
        #expect(PortBrokerRecheck.isSettled(.notRegistered, wanting: false))
        #expect(!PortBrokerRecheck.isSettled(.enabled, wanting: false))
        #expect(!PortBrokerRecheck.isSettled(.requiresApproval, wanting: false))
    }
}
