import Foundation

/// The founding identity fields that should remain stable for the lifetime of
/// one Thane. A mismatch is the identity equivalent of Signal's safety-number
/// change: it may be legitimate, but the operator must review it explicitly.
nonisolated struct FoundingIdentityPin: Codable, Equatable, Sendable {
    let instanceID: String
    let instanceName: String
    let identityKeyAlgorithm: String
    let identityKeyFingerprint: String
    let channelCAAlgorithm: String
    let channelCAFingerprint: String
    let birthCommitAlgorithm: String
    let birthCommitOID: String
    let assertedBirth: String
    let timeAssurance: String
    let anchor: String

    init(
        instanceID: String,
        instanceName: String,
        identityKeyAlgorithm: String,
        identityKeyFingerprint: String,
        channelCAAlgorithm: String,
        channelCAFingerprint: String,
        birthCommitAlgorithm: String,
        birthCommitOID: String,
        assertedBirth: String,
        timeAssurance: String,
        anchor: String
    ) {
        self.instanceID = instanceID
        self.instanceName = instanceName
        self.identityKeyAlgorithm = identityKeyAlgorithm
        self.identityKeyFingerprint = identityKeyFingerprint
        self.channelCAAlgorithm = channelCAAlgorithm
        self.channelCAFingerprint = channelCAFingerprint
        self.birthCommitAlgorithm = birthCommitAlgorithm
        self.birthCommitOID = birthCommitOID
        self.assertedBirth = assertedBirth
        self.timeAssurance = timeAssurance
        self.anchor = anchor
    }

    init(evidence: IdentityEvidence) {
        instanceID = evidence.instance.id
        instanceName = evidence.instance.name
        identityKeyAlgorithm = evidence.instance.identityKey.algorithm
        identityKeyFingerprint = evidence.instance.identityKey.fingerprint
        channelCAAlgorithm = evidence.instance.channelCA.algorithm
        channelCAFingerprint = evidence.instance.channelCA.fingerprint
        birthCommitAlgorithm = evidence.core.birth.commit.algorithm
        birthCommitOID = evidence.core.birth.commit.oid
        assertedBirth = evidence.core.birth.assertedAt
        timeAssurance = evidence.core.birth.timeAssurance
        anchor = evidence.core.birth.anchor
    }

    func changes(from previous: Self) -> [IdentityPinChange] {
        var changes: [IdentityPinChange] = []
        appendChange("Instance ID", previous.instanceID, instanceID, to: &changes)
        appendChange("Instance name", previous.instanceName, instanceName, to: &changes)
        appendChange(
            "Identity key algorithm",
            previous.identityKeyAlgorithm,
            identityKeyAlgorithm,
            to: &changes
        )
        appendChange(
            "Identity key fingerprint",
            previous.identityKeyFingerprint,
            identityKeyFingerprint,
            to: &changes
        )
        appendChange(
            "Channel CA algorithm",
            previous.channelCAAlgorithm,
            channelCAAlgorithm,
            to: &changes
        )
        appendChange(
            "Channel CA fingerprint",
            previous.channelCAFingerprint,
            channelCAFingerprint,
            to: &changes
        )
        appendChange(
            "Birth commit algorithm",
            previous.birthCommitAlgorithm,
            birthCommitAlgorithm,
            to: &changes
        )
        appendChange("Birth commit", previous.birthCommitOID, birthCommitOID, to: &changes)
        appendChange("Asserted birth", previous.assertedBirth, assertedBirth, to: &changes)
        appendChange("Time assurance", previous.timeAssurance, timeAssurance, to: &changes)
        appendChange("Founding posture", previous.anchor, anchor, to: &changes)
        return changes
    }

    private func appendChange(
        _ field: String,
        _ previous: String,
        _ current: String,
        to changes: inout [IdentityPinChange]
    ) {
        guard previous != current else { return }
        changes.append(IdentityPinChange(field: field, previous: previous, current: current))
    }
}

nonisolated struct IdentityPinChange: Identifiable, Equatable, Sendable {
    let field: String
    let previous: String
    let current: String

    var id: String { field }
}

nonisolated struct StoredIdentityPin: Codable, Equatable, Sendable {
    let pin: FoundingIdentityPin
    let firstSeenAt: Date
    let firstSeenCommitAlgorithm: String
    let firstSeenCommitOID: String
    let highestTrustFileChangeCount: Int

    func changes(
        to current: FoundingIdentityPin,
        trustFileChangeCount: Int
    ) -> [IdentityPinChange] {
        var changes = current.changes(from: pin)
        if trustFileChangeCount < highestTrustFileChangeCount {
            changes.append(IdentityPinChange(
                field: "Trust-file revision count",
                previous: "\(highestTrustFileChangeCount)",
                current: "\(trustFileChangeCount)"
            ))
        }
        return changes
    }
}

@MainActor
struct IdentityPinStore {
    private enum Backend {
        case keychain
        case defaults(UserDefaults)
    }

    private let backend: Backend
    private static let keyPrefix = "foundingIdentityPin."

    init() {
        backend = .keychain
    }

    init(defaults: UserDefaults) {
        backend = .defaults(defaults)
    }

    func load(for baseURL: URL) throws -> StoredIdentityPin? {
        let account = key(for: baseURL)
        let data: Data?
        switch backend {
        case .keychain:
            data = KeychainHelper.load(key: account)?.data(using: .utf8)
        case .defaults(let defaults):
            data = defaults.data(forKey: account)
        }
        guard let data else { return nil }
        return try JSONDecoder().decode(StoredIdentityPin.self, from: data)
    }

    func save(_ pin: StoredIdentityPin, for baseURL: URL) throws {
        let data = try JSONEncoder().encode(pin)
        switch backend {
        case .keychain:
            guard let value = String(data: data, encoding: .utf8) else {
                throw IdentityPinStoreError.encodingFailed
            }
            try KeychainHelper.save(key: key(for: baseURL), value: value)
        case .defaults(let defaults):
            defaults.set(data, forKey: key(for: baseURL))
        }
    }

    func remove(for baseURL: URL) {
        switch backend {
        case .keychain:
            KeychainHelper.delete(key: key(for: baseURL))
        case .defaults(let defaults):
            defaults.removeObject(forKey: key(for: baseURL))
        }
    }

    /// Pins follow the connection origin, analogous to associating a Signal
    /// safety number with a contact. Path and query components do not create a
    /// separate identity relationship.
    func key(for baseURL: URL) -> String {
        let scheme = baseURL.scheme?.lowercased() ?? ""
        let rawHost = baseURL.host?.lowercased() ?? ""
        let host = rawHost.contains(":") ? "[\(rawHost)]" : rawHost
        let defaultPort: Int? = switch scheme {
        case "http": 80
        case "https": 443
        default: nil
        }
        let port = baseURL.port.flatMap { $0 == defaultPort ? nil : ":\($0)" } ?? ""
        return Self.keyPrefix + scheme + "://" + host + port
    }
}

nonisolated enum IdentityPinStoreError: LocalizedError {
    case encodingFailed

    var errorDescription: String? {
        "Could not encode the saved Thane identity"
    }
}

enum IdentityPinState {
    case unavailable
    case matches(StoredIdentityPin, firstObservation: Bool)
    case changed(previous: StoredIdentityPin, current: FoundingIdentityPin, changes: [IdentityPinChange])

    var hasChanged: Bool {
        if case .changed = self { true } else { false }
    }
}
