import EventKit
import Foundation
import Testing
@testable import thane_agent_macos

/// Counts refresh callbacks and lets a test wait for one without sleeping a
/// fixed interval or hanging forever if it never arrives.
private actor RefreshCounter {
    private var count = 0

    func record() {
        count += 1
    }

    func current() -> Int {
        count
    }

    /// Waits for the count to reach `target`, giving up after roughly a
    /// second. Returns the count actually reached, so a caller can assert on
    /// the real value rather than on a timeout.
    func wait(for target: Int) async -> Int {
        for _ in 0..<200 {
            if count >= target {
                return count
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return count
    }
}

struct EventKitChangeObserverTests {
    @Test
    func forwardsAnEventKitChangeToItsOwner() async {
        // A private center so the test never sees, or is seen by, real
        // EventKit traffic on this machine.
        let center = NotificationCenter()
        let counter = RefreshCounter()
        let observer = EventKitChangeObserver(center: center) { await counter.record() }

        observer.start()
        defer { observer.stop() }
        center.post(name: .EKEventStoreChanged, object: nil)

        #expect(await counter.wait(for: 1) == 1)
    }

    @Test
    func forwardsEveryChangeNotJustTheFirst() async {
        let center = NotificationCenter()
        let counter = RefreshCounter()
        let observer = EventKitChangeObserver(center: center) { await counter.record() }

        observer.start()
        defer { observer.stop() }
        center.post(name: .EKEventStoreChanged, object: nil)
        center.post(name: .EKEventStoreChanged, object: nil)
        center.post(name: .EKEventStoreChanged, object: nil)

        #expect(await counter.wait(for: 3) == 3)
    }

    @Test
    func startingTwiceRegistersOnce() async {
        // A double start would reset the store twice per change — harmless
        // but wasteful, and a sign the caller cannot tell what state it is
        // in.
        let center = NotificationCenter()
        let counter = RefreshCounter()
        let observer = EventKitChangeObserver(center: center) { await counter.record() }

        observer.start()
        observer.start()
        defer { observer.stop() }
        center.post(name: .EKEventStoreChanged, object: nil)

        #expect(await counter.wait(for: 2) == 1)
    }

    @Test
    func stopEndsTheSubscription() async {
        let center = NotificationCenter()
        let counter = RefreshCounter()
        let observer = EventKitChangeObserver(center: center) { await counter.record() }

        observer.start()
        center.post(name: .EKEventStoreChanged, object: nil)
        #expect(await counter.wait(for: 1) == 1)

        observer.stop()
        #expect(observer.isObserving == false)

        center.post(name: .EKEventStoreChanged, object: nil)
        #expect(await counter.wait(for: 2) == 1)
    }

    @Test
    func stopWithoutStartIsHarmless() async {
        let observer = EventKitChangeObserver(center: NotificationCenter()) {}

        observer.stop()

        #expect(observer.isObserving == false)
    }

    @Test
    func ignoresUnrelatedNotifications() async {
        let center = NotificationCenter()
        let counter = RefreshCounter()
        let observer = EventKitChangeObserver(center: center) { await counter.record() }

        observer.start()
        defer { observer.stop() }
        center.post(name: Notification.Name("SomethingElseEntirely"), object: nil)

        #expect(await counter.wait(for: 1) == 0)
    }

    @Test
    func releasingAnObserverEndsItsSubscription() async {
        // A block-based registration is retained by the center, and the
        // block holds the handler rather than the observer — so without a
        // deinit backstop an observer that simply goes out of scope leaves a
        // live registration that nothing can reach and nothing will remove.
        let center = NotificationCenter()
        let counter = RefreshCounter()

        do {
            let observer = EventKitChangeObserver(center: center) { await counter.record() }
            observer.start()
        }

        center.post(name: .EKEventStoreChanged, object: nil)

        #expect(await counter.wait(for: 1) == 0)
    }

    @Test
    func servicesStartObservingIdempotently() async {
        // The services register against the real default center, so this
        // only asserts that starting twice does not trap or double-register
        // — the forwarding behaviour is covered above. Both are torn down so
        // the test leaves no registration behind for the rest of the run.
        let calendar = CalendarService()
        await calendar.startObservingChanges()
        await calendar.startObservingChanges()
        await calendar.stopObservingChanges()

        let reminders = RemindersService()
        await reminders.startObservingChanges()
        await reminders.startObservingChanges()
        await reminders.stopObservingChanges()
    }
}
