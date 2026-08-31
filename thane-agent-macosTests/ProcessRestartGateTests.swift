import Testing
@testable import thane_agent_macos

struct ProcessRestartGateTests {
    @Test
    func startsImmediatelyWhenNoProcessIsRunning() {
        var gate = ProcessRestartGate()

        let startNow = gate.request(processIsRunning: false)

        #expect(startNow)
        #expect(gate.isPending == false)
    }

    @Test
    func holdsTheRestartUntilTheRunningProcessActuallyTerminates() {
        var gate = ProcessRestartGate()

        let startNow = gate.request(processIsRunning: true)

        #expect(startNow == false)
        #expect(gate.isPending)

        let restartAfterTermination = gate.consumeAfterTermination(
            isClean: true,
            shouldRun: true
        )

        #expect(restartAfterTermination)
        #expect(gate.isPending == false)
    }

    @Test
    func anOperatorStopCancelsThePendingRestart() {
        var gate = ProcessRestartGate()
        _ = gate.request(processIsRunning: true)

        gate.cancel()

        let restartAfterTermination = gate.consumeAfterTermination(
            isClean: true,
            shouldRun: true
        )
        #expect(restartAfterTermination == false)
    }

    @Test
    func clearedRunIntentPreventsThePendingRestart() {
        var gate = ProcessRestartGate()
        _ = gate.request(processIsRunning: true)

        let restartAfterTermination = gate.consumeAfterTermination(
            isClean: true,
            shouldRun: false
        )

        #expect(restartAfterTermination == false)
        #expect(gate.isPending == false)
    }

    @Test
    func aCrashUsesTheNormalBackoffPathInsteadOfImmediateRestart() {
        var gate = ProcessRestartGate()
        _ = gate.request(processIsRunning: true)

        let restartAfterTermination = gate.consumeAfterTermination(
            isClean: false,
            shouldRun: true
        )

        #expect(restartAfterTermination == false)
        #expect(gate.isPending == false)
    }
}
