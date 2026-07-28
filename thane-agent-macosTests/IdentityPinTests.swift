import Foundation
import Testing
@testable import thane_agent_macos

struct IdentityPinTests {
    @Test func unchangedPinHasNoChanges() {
        let pin = Self.pin()
        #expect(pin.changes(from: pin).isEmpty)
    }

    @Test func reportsEveryChangedFoundingField() {
        let previous = Self.pin()
        let current = FoundingIdentityPin(
            instanceID: "thane:changed",
            instanceName: "other",
            identityKeyAlgorithm: "other-key",
            identityKeyFingerprint: "SHA256:new-key",
            channelCAAlgorithm: "other-ca",
            channelCAFingerprint: "SHA256:new-ca",
            birthCommitAlgorithm: "sha256",
            birthCommitOID: "2222",
            assertedBirth: "2027-01-01T00:00:00Z",
            timeAssurance: "witnessed",
            anchor: "self_signed"
        )

        #expect(current.changes(from: previous).map(\.field) == [
            "Instance ID",
            "Instance name",
            "Identity key algorithm",
            "Identity key fingerprint",
            "Channel CA algorithm",
            "Channel CA fingerprint",
            "Birth commit algorithm",
            "Birth commit",
            "Asserted birth",
            "Time assurance",
            "Founding posture",
        ])
    }

    @Test @MainActor func storeKeysPinsByOriginAndRoundTrips() throws {
        let suite = "IdentityPinTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = IdentityPinStore(defaults: defaults)
        let firstURL = try #require(URL(string: "https://example.com/one?query=yes"))
        let sameOrigin = try #require(URL(string: "https://EXAMPLE.com:443/two"))
        let otherPort = try #require(URL(string: "https://example.com:8443"))
        let stored = StoredIdentityPin(
            pin: Self.pin(),
            firstSeenAt: Date(timeIntervalSince1970: 123),
            firstSeenCommitAlgorithm: "sha1",
            firstSeenCommitOID: "abcd",
            highestTrustFileChangeCount: 2
        )

        try store.save(stored, for: firstURL)

        #expect(try store.load(for: sameOrigin) == stored)
        #expect(try store.load(for: otherPort) == nil)
    }

    @Test func trustFileRevisionCountMayAdvanceButMustNotMoveBackward() {
        let stored = StoredIdentityPin(
            pin: Self.pin(),
            firstSeenAt: Date(timeIntervalSince1970: 123),
            firstSeenCommitAlgorithm: "sha1",
            firstSeenCommitOID: "abcd",
            highestTrustFileChangeCount: 2
        )

        #expect(stored.changes(to: Self.pin(), trustFileChangeCount: 3).isEmpty)
        #expect(stored.changes(to: Self.pin(), trustFileChangeCount: 1) == [
            IdentityPinChange(
                field: "Trust-file revision count",
                previous: "2",
                current: "1"
            )
        ])
    }

    private static func pin() -> FoundingIdentityPin {
        FoundingIdentityPin(
            instanceID: "thane:original",
            instanceName: "centro",
            identityKeyAlgorithm: "ed25519",
            identityKeyFingerprint: "SHA256:key",
            channelCAAlgorithm: "x509-ed25519",
            channelCAFingerprint: "SHA256:ca",
            birthCommitAlgorithm: "sha1",
            birthCommitOID: "1111",
            assertedBirth: "2026-01-01T00:00:00Z",
            timeAssurance: "signed_claim",
            anchor: "operator"
        )
    }
}
