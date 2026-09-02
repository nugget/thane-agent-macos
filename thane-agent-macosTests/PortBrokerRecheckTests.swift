import ServiceManagement
import Testing
@testable import thane_agent_macos

/// The re-check schedule after the privileged-ports toggle: Background Task
/// Management writes its record seconds after registration returns, so the
/// view keeps looking until the answer is one that waiting cannot change.
struct PortBrokerRecheckTests {

    @Test func scheduleIsAscendingAndCoversTheObservedLag() {
        let delays = PortBrokerRecheck.delays
        #expect(delays.count >= 3)
        for (a, b) in zip(delays, delays.dropFirst()) {
            #expect(a < b, "re-check delays should grow")
        }
        #expect(delays.last! >= .seconds(30), "BTM took about thirty seconds on the operator's machine")
    }

    @Test func settledStatesStopThePolling() {
        #expect(PortBrokerRecheck.isSettled(.enabled))
        #expect(PortBrokerRecheck.isSettled(.notRegistered))
        #expect(!PortBrokerRecheck.isSettled(.requiresApproval))
        #expect(!PortBrokerRecheck.isSettled(.notFound))
    }
}
