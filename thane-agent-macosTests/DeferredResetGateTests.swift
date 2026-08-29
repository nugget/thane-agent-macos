import Foundation
import Testing
@testable import thane_agent_macos

struct DeferredResetGateTests {
    @Test
    func resetsImmediatelyWhenNothingIsInFlight() {
        var gate = DeferredResetGate()

        let now = gate.requestReset()

        #expect(now)
        #expect(gate.isResetPending == false)
    }

    @Test
    func holdsAResetBackWhileWorkIsOutstanding() {
        var gate = DeferredResetGate()
        gate.beginWork()

        let now = gate.requestReset()

        #expect(now == false)
        #expect(gate.isResetPending)
    }

    @Test
    func releasesTheDeferredResetWhenTheWorkEnds() {
        var gate = DeferredResetGate()
        gate.beginWork()
        _ = gate.requestReset()

        let released = gate.endWork()

        #expect(released)
        #expect(gate.isResetPending == false)
    }

    @Test
    func waitsForTheLastOfSeveralOverlappingFetches() {
        // Two list requests can overlap. A flag cleared by the first would
        // reset the store while the second is still mapping.
        var gate = DeferredResetGate()
        gate.beginWork()
        gate.beginWork()
        _ = gate.requestReset()

        let afterFirst = gate.endWork()
        #expect(afterFirst == false, "the first fetch must not release the reset")
        #expect(gate.isResetPending)

        let afterLast = gate.endWork()
        #expect(afterLast, "the last fetch releases it")
    }

    @Test
    func endingWorkWithNoResetPendingDoesNothing() {
        var gate = DeferredResetGate()
        gate.beginWork()

        let released = gate.endWork()

        #expect(released == false)
    }

    @Test
    func collapsesRepeatedResetsIntoOne() {
        // A burst of change notifications during one fetch should cost one
        // reset, not one per notification.
        var gate = DeferredResetGate()
        gate.beginWork()
        _ = gate.requestReset()
        _ = gate.requestReset()
        _ = gate.requestReset()

        let released = gate.endWork()
        #expect(released)

        let again = gate.endWork()
        #expect(again == false, "the deferral is released exactly once")
    }

    @Test
    func aDeferredResetIsNeverSkipped() {
        // The property that matters: after any interleaving, a requested
        // reset has either been applied or is still pending — it cannot be
        // silently dropped, which would leave the store stale indefinitely.
        var gate = DeferredResetGate()

        gate.beginWork()
        var applied = gate.requestReset()
        gate.beginWork()
        let first = gate.endWork()
        let second = gate.endWork()
        applied = applied || first || second

        #expect(applied)
        #expect(gate.isResetPending == false)
        #expect(gate.inFlight == 0)
    }

    @Test
    func unbalancedEndWorkCannotDriveTheCountNegative() {
        // A stray end must not leave the gate believing work is outstanding
        // forever after, which would wedge every future reset.
        var gate = DeferredResetGate()

        let released = gate.endWork()
        #expect(released == false)
        #expect(gate.inFlight == 0)

        let usable = gate.requestReset()
        #expect(usable, "the gate must still be usable")
    }
}
