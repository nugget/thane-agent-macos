import Foundation
import Security

// MARK: - Apple Code Signature

/// Inspects and surfaces macOS code signature details for a binary.
///
/// Uses Security.framework (`SecStaticCode`) and `spctl` to extract
/// Team ID, signing identity, notarization status, and certificate chain.
struct AppleCodeSignature: Sendable {

    enum Status: Sendable, Equatable {
        case notarized(teamID: String, identity: String)
        case signed(teamID: String, identity: String)
        case adhoc
        case unsigned
        case error(String)
    }

    let status: Status
    let teamID: String?
    let signingIdentity: String?
    let isNotarized: Bool
    let certificateChain: [String]

    var summary: String {
        switch status {
        case .notarized(let team, _):
            return "Notarized \u{2014} Developer ID (\(team))"
        case .signed(let team, _):
            return "Signed \u{2014} Developer ID (\(team))"
        case .adhoc:
            return "Ad-hoc signed (no identity)"
        case .unsigned:
            return "Not code signed"
        case .error(let msg):
            return "Signature check failed: \(msg)"
        }
    }

    var isVerified: Bool {
        switch status {
        case .notarized, .signed: true
        default: false
        }
    }

    var details: [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = []
        if let team = teamID {
            rows.append(("Team ID", team))
        }
        if let identity = signingIdentity {
            rows.append(("Signing Identity", identity))
        }
        rows.append(("Notarized", isNotarized ? "Yes" : "No"))
        for (i, cn) in certificateChain.enumerated() {
            let label = i == 0 ? "Leaf Certificate" : "Certificate [\(i)]"
            rows.append((label, cn))
        }
        return rows
    }

    // MARK: - Inspection

    /// Inspect the Apple code signature on a binary at the given URL.
    /// Runs Security.framework calls and an `spctl` subprocess off the
    /// main actor.
    nonisolated static func inspect(binaryURL: URL) async -> AppleCodeSignature {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = inspectSync(binaryURL: binaryURL)
                continuation.resume(returning: result)
            }
        }
    }

    nonisolated private static func inspectSync(binaryURL: URL) -> AppleCodeSignature {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            binaryURL as CFURL,
            SecCSFlags(rawValue: 0),
            &staticCode
        )
        guard createStatus == errSecSuccess, let code = staticCode else {
            return AppleCodeSignature(
                status: .error("Failed to create static code object (OSStatus \(createStatus))"),
                teamID: nil, signingIdentity: nil, isNotarized: false, certificateChain: []
            )
        }

        let validityStatus = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: 0), nil)
        if validityStatus == errSecCSUnsigned {
            return AppleCodeSignature(
                status: .unsigned,
                teamID: nil, signingIdentity: nil, isNotarized: false, certificateChain: []
            )
        }
        if validityStatus != errSecSuccess {
            return AppleCodeSignature(
                status: .error("Signature validation failed (OSStatus \(validityStatus))"),
                teamID: nil, signingIdentity: nil, isNotarized: false, certificateChain: []
            )
        }

        // Extract signing information
        var infoRef: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &infoRef
        )
        guard infoStatus == errSecSuccess, let info = infoRef as? [String: Any] else {
            return AppleCodeSignature(
                status: .error("Failed to read signing information"),
                teamID: nil, signingIdentity: nil, isNotarized: false, certificateChain: []
            )
        }

        let identity = info[kSecCodeInfoIdentifier as String] as? String
        let team = info[kSecCodeInfoTeamIdentifier as String] as? String
        var chain: [String] = []

        if let certs = info[kSecCodeInfoCertificates as String] as? [SecCertificate] {
            for cert in certs {
                if let summary = SecCertificateCopySubjectSummary(cert) as String? {
                    chain.append(summary)
                }
            }
        }

        // Ad-hoc: signed but no team or certificates
        if team == nil && chain.isEmpty {
            return AppleCodeSignature(
                status: .adhoc,
                teamID: nil, signingIdentity: identity, isNotarized: false, certificateChain: []
            )
        }

        // Check notarization via spctl
        let notarized = checkNotarization(binaryURL: binaryURL)

        let status: Status
        if notarized, let team, let identity {
            status = .notarized(teamID: team, identity: identity)
        } else if let team, let identity {
            status = .signed(teamID: team, identity: identity)
        } else if let team {
            status = .signed(teamID: team, identity: identity ?? "Unknown")
        } else {
            status = .adhoc
        }

        return AppleCodeSignature(
            status: status,
            teamID: team,
            signingIdentity: identity,
            isNotarized: notarized,
            certificateChain: chain
        )
    }

    nonisolated private static func checkNotarization(binaryURL: URL) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/spctl")
        proc.arguments = ["-a", "-t", "exec", "-vvv", binaryURL.path]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return false
        }

        guard let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else {
            return false
        }

        // spctl output includes "Notarized Developer ID" for notarized binaries
        return output.contains("Notarized Developer ID")
    }
}
