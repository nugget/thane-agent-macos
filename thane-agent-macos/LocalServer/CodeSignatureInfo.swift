import Foundation
import Security

// MARK: - Apple Code Signature

/// Inspects macOS code signature details for a binary using Security.framework.
///
/// This reports the binary's own code signature — Team ID, signing identity,
/// and certificate chain. It does **not** check notarization: Apple does not
/// support stapling notarization tickets to standalone CLI binaries. Package-
/// level notarization is tracked separately via install provenance.
struct AppleCodeSignature: Sendable {

    enum Status: Sendable, Equatable {
        case signed(teamID: String, identity: String)
        case adhoc
        case unsigned
        case error(String)
    }

    let status: Status
    let teamID: String?
    let signingIdentity: String?
    let certificateChain: [String]

    var summary: String {
        switch status {
        case .signed(let team, _):
            return "Developer ID signed (\(team))"
        case .adhoc:
            return "Ad-hoc signed (no identity)"
        case .unsigned:
            return "Not code signed"
        case .error(let msg):
            return "Signature check failed: \(msg)"
        }
    }

    var isVerified: Bool {
        if case .signed = status { return true }
        return false
    }

    var details: [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = []
        if let team = teamID {
            rows.append(("Team ID", team))
        }
        if let identity = signingIdentity {
            rows.append(("Signing Identity", identity))
        }
        for (i, cn) in certificateChain.enumerated() {
            let label = i == 0 ? "Leaf Certificate" : "Certificate [\(i)]"
            rows.append((label, cn))
        }
        return rows
    }

    // MARK: - Inspection

    /// Inspect the Apple code signature on a binary. Checks the code signature
    /// only — not notarization, which is a package-level property.
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
                teamID: nil, signingIdentity: nil, certificateChain: []
            )
        }

        let validityStatus = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: 0), nil)
        if validityStatus == errSecCSUnsigned {
            return AppleCodeSignature(
                status: .unsigned,
                teamID: nil, signingIdentity: nil, certificateChain: []
            )
        }
        if validityStatus != errSecSuccess {
            return AppleCodeSignature(
                status: .error("Signature validation failed (OSStatus \(validityStatus))"),
                teamID: nil, signingIdentity: nil, certificateChain: []
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
                teamID: nil, signingIdentity: nil, certificateChain: []
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
                teamID: nil, signingIdentity: identity, certificateChain: []
            )
        }

        let status: Status
        if let team, let identity {
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
            certificateChain: chain
        )
    }
}

// MARK: - Package Signature

/// Checks the signing and notarization status of a .pkg installer package
/// using `pkgutil --check-signature`.
struct PackageSignatureInfo: Sendable {
    let isSigned: Bool
    let signingTeamID: String?
    let isNotarized: Bool
    let rawOutput: String

    var summary: String {
        if isNotarized {
            return "Notarized package"
        } else if isSigned {
            return "Signed package"
        } else {
            return "Unsigned package"
        }
    }

    /// Check the signature and notarization status of a .pkg file.
    nonisolated static func inspect(pkgURL: URL) async -> PackageSignatureInfo {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = inspectSync(pkgURL: pkgURL)
                continuation.resume(returning: result)
            }
        }
    }

    nonisolated private static func inspectSync(pkgURL: URL) -> PackageSignatureInfo {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
        proc.arguments = ["--check-signature", pkgURL.path]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return PackageSignatureInfo(
                isSigned: false, signingTeamID: nil,
                isNotarized: false, rawOutput: error.localizedDescription
            )
        }

        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        let isSigned = output.contains("Developer ID Installer")
        let isNotarized = output.contains("notarized")

        // Extract team ID from output like "(XXXXXXXXXX)"
        var teamID: String?
        if let range = output.range(of: #"\([A-Z0-9]{10}\)"#, options: .regularExpression) {
            let match = output[range]
            teamID = String(match.dropFirst().dropLast())
        }

        return PackageSignatureInfo(
            isSigned: isSigned, signingTeamID: teamID,
            isNotarized: isNotarized, rawOutput: output
        )
    }
}
