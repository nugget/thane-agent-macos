import CryptoKit
import Foundation
import os

// MARK: - Semantic Version

struct SemanticVersion: Comparable, CustomStringConvertible, Sendable {
    let major: Int
    let minor: Int
    let patch: Int
    let preRelease: String?

    var description: String {
        var s = "\(major).\(minor).\(patch)"
        if let pre = preRelease { s += "-\(pre)" }
        return s
    }

    /// Parse a version string like "v0.9.0-rc", "0.9.0", or "1.2.3-beta.1".
    init?(_ string: String) {
        var s = string
        if s.hasPrefix("v") || s.hasPrefix("V") { s = String(s.dropFirst()) }

        let dashSplit = s.split(separator: "-", maxSplits: 1)
        let coreParts = dashSplit[0].split(separator: ".")

        guard coreParts.count == 3,
              let maj = Int(coreParts[0]),
              let min = Int(coreParts[1]),
              let pat = Int(coreParts[2]) else { return nil }

        major = maj
        minor = min
        patch = pat
        preRelease = dashSplit.count > 1 ? String(dashSplit[1]) : nil
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        // Pre-release sorts below stable at the same version
        switch (lhs.preRelease, rhs.preRelease) {
        case (nil, nil):    return false
        case (_, nil):      return true   // "0.9.0-rc" < "0.9.0"
        case (nil, _):      return false  // "0.9.0" > "0.9.0-rc"
        case (let l?, let r?): return l < r
        }
    }
}

// MARK: - Available Release

struct AvailableRelease: Sendable {
    let version: SemanticVersion
    let tagName: String
    let assetURL: URL
    let checksumURL: URL
    let htmlURL: URL
    let isPreRelease: Bool
    let publishedAt: Date
    let changelog: String?
}

// MARK: - Update State

enum UpdateState: Equatable {
    case idle
    case checking
    case available(version: String)
    case downloading(progress: Double)
    case verifying
    case installing
    case installed(version: String)
    case failed(message: String)
}

// MARK: - Update Manager

@Observable
@MainActor
final class UpdateManager {

    private(set) var state: UpdateState = .idle
    private(set) var availableRelease: AvailableRelease?

    var autoUpdateEnabled: Bool {
        didSet { UserDefaults.standard.set(autoUpdateEnabled, forKey: "autoUpdateEnabled") }
    }
    var includePreReleases: Bool {
        didSet { UserDefaults.standard.set(includePreReleases, forKey: "updateIncludePreReleases") }
    }
    private(set) var lastCheckDate: Date? {
        didSet {
            if let d = lastCheckDate {
                UserDefaults.standard.set(d.timeIntervalSince1970, forKey: "updateLastCheckDate")
            }
        }
    }

    private let logger = Logger(subsystem: "info.nugget.thane-agent-macos", category: "update")
    private var periodicCheckTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var activeDownloadTask: URLSessionDownloadTask?

    private static let repoOwner = "nugget"
    private static let repoName = "thane-ai-agent"
    private static let checkIntervalSeconds: TimeInterval = 86400 // 24 hours

    // Read from GitHubReleaseResponse (a nonisolated struct), so must be
    // nonisolated itself. Safe — it's an immutable string constant.
    #if arch(arm64)
    nonisolated static let platformSuffix = "darwin_arm64.pkg"
    #elseif arch(x86_64)
    nonisolated static let platformSuffix = "darwin_amd64.pkg"
    #endif

    init() {
        autoUpdateEnabled = UserDefaults.standard.bool(forKey: "autoUpdateEnabled")
        includePreReleases = UserDefaults.standard.bool(forKey: "updateIncludePreReleases")
        let ts = UserDefaults.standard.double(forKey: "updateLastCheckDate")
        lastCheckDate = ts > 0 ? Date(timeIntervalSince1970: ts) : nil
    }

    // MARK: - Check for Updates

    func checkForUpdate(currentVersion: String?) async {
        state = .checking
        availableRelease = nil

        do {
            let release = try await fetchLatestRelease()
            lastCheckDate = Date()

            guard let assetURL = release.assetURL,
                  let checksumURL = release.checksumURL else {
                logger.warning("No matching platform asset in release \(release.tagName)")
                state = .idle
                return
            }

            guard let remoteVersion = SemanticVersion(release.tagName) else {
                logger.error("Cannot parse release tag as semver: \(release.tagName)")
                state = .idle
                return
            }

            let currentSemver = currentVersion.flatMap { SemanticVersion($0) }
            if let current = currentSemver, remoteVersion <= current {
                logger.info("Current version \(current) is up to date (remote: \(remoteVersion))")
                state = .idle
                return
            }

            let available = AvailableRelease(
                version: remoteVersion,
                tagName: release.tagName,
                assetURL: assetURL,
                checksumURL: checksumURL,
                htmlURL: release.htmlURL,
                isPreRelease: release.isPreRelease,
                publishedAt: release.publishedDate,
                changelog: release.body
            )
            availableRelease = available
            state = .available(version: remoteVersion.description)
            logger.info("Update available: \(remoteVersion)")
        } catch {
            logger.error("Update check failed: \(error.localizedDescription)")
            state = .failed(message: error.localizedDescription)
        }
    }

    // MARK: - Download and Install

    func downloadAndInstall(binaryManager: BinaryManager) {
        guard let release = availableRelease, state == .available(version: release.version.description) else { return }

        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await performDownloadAndInstall(release: release, binaryManager: binaryManager)
            } catch is CancellationError {
                state = .available(version: release.version.description)
            } catch {
                logger.error("Update failed: \(error.localizedDescription)")
                state = .failed(message: error.localizedDescription)
            }
        }
    }

    func cancelDownload() {
        activeDownloadTask?.cancel()
        activeDownloadTask = nil
        downloadTask?.cancel()
        downloadTask = nil
        if let release = availableRelease {
            state = .available(version: release.version.description)
        } else {
            state = .idle
        }
    }

    // MARK: - Periodic Checks

    func startPeriodicChecks(currentVersionProvider: @escaping @MainActor () -> String?) {
        periodicCheckTask?.cancel()
        periodicCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if autoUpdateEnabled {
                    let shouldCheck: Bool
                    if let last = lastCheckDate {
                        shouldCheck = Date().timeIntervalSince(last) >= Self.checkIntervalSeconds
                    } else {
                        shouldCheck = true
                    }
                    if shouldCheck {
                        await checkForUpdate(currentVersion: currentVersionProvider())
                    }
                }
                do {
                    try await Task.sleep(for: .seconds(3600)) // Re-evaluate hourly
                } catch { break }
            }
        }
    }

    // MARK: - Private: Download + Install

    private func performDownloadAndInstall(release: AvailableRelease, binaryManager: BinaryManager) async throws {
        state = .downloading(progress: 0)
        let fm = FileManager.default

        // Download archive to temp file with progress tracking
        let archiveFilename = release.assetURL.lastPathComponent
        let tempFileURL = try await downloadFile(from: release.assetURL)
        activeDownloadTask = nil
        try Task.checkCancellation()

        // Move to a location we control (system may clean the original)
        let tempDir = fm.temporaryDirectory.appending(component: "thane-update-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let archivePath = tempDir.appending(component: archiveFilename)
        try fm.moveItem(at: tempFileURL, to: archivePath)

        // Download checksums
        state = .verifying
        let (checksumData, _) = try await URLSession.shared.data(from: release.checksumURL)
        try Task.checkCancellation()

        // Verify SHA-256
        guard let checksumText = String(data: checksumData, encoding: .utf8) else {
            throw UpdateError.checksumParseFailure
        }
        let expectedHash = parseChecksum(text: checksumText, filename: archiveFilename)
        guard let expectedHash else {
            throw UpdateError.checksumNotFound(filename: archiveFilename)
        }
        let archiveData = try Data(contentsOf: archivePath)
        let actualHash = SHA256.hash(data: archiveData).map { String(format: "%02x", $0) }.joined()
        guard actualHash == expectedHash else {
            logger.error("SHA-256 mismatch: expected \(expectedHash), got \(actualHash)")
            try? fm.removeItem(at: tempDir)
            throw UpdateError.checksumMismatch
        }
        logger.info("SHA-256 verified for \(archiveFilename)")

        defer { try? fm.removeItem(at: tempDir) }

        // Verify package signature and record provenance
        let pkgSignature = await PackageSignatureInfo.inspect(pkgURL: archivePath)
        let provenance: BinaryManager.InstallProvenance
        if pkgSignature.isNotarized {
            provenance = .notarizedPackage
        } else if pkgSignature.isSigned {
            provenance = .signedPackage
        } else {
            provenance = .unsignedPackage
        }
        logger.info("Package provenance: \(provenance.rawValue) (\(pkgSignature.summary))")

        // Extract pkg payload
        let extractDir = tempDir.appending(component: "expanded")
        try await expandPackage(pkgPath: archivePath, destination: extractDir)
        try Task.checkCancellation()

        // Locate binary
        guard let binaryPath = findBinary(in: extractDir) else {
            throw UpdateError.binaryNotFoundInArchive
        }

        // Install
        state = .installing
        let installURL = BinaryManager.managedBinaryURL
        let installDir = installURL.deletingLastPathComponent()
        let backupURL = installURL.appendingPathExtension("backup")

        try await binaryManager.performMaintenance {
            let mgr = FileManager.default
            if !mgr.fileExists(atPath: installDir.path) {
                try mgr.createDirectory(at: installDir, withIntermediateDirectories: true)
            }
            // Backup existing
            if mgr.fileExists(atPath: installURL.path) {
                if mgr.fileExists(atPath: backupURL.path) {
                    try mgr.removeItem(at: backupURL)
                }
                try mgr.moveItem(at: installURL, to: backupURL)
            }
            do {
                try mgr.moveItem(at: binaryPath, to: installURL)
                try mgr.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: installURL.path
                )
            } catch {
                // Restore backup on failure
                if mgr.fileExists(atPath: backupURL.path) {
                    try? mgr.moveItem(at: backupURL, to: installURL)
                }
                throw error
            }
        }

        binaryManager.binaryURL = installURL
        binaryManager.setInstallProvenance(provenance)

        // Clean up backup
        try? fm.removeItem(at: backupURL)

        state = .installed(version: release.version.description)
        logger.info("Updated to \(release.version)")
    }

    private func downloadFile(from url: URL) async throws -> URL {
        let delegate = DownloadDelegate(tempFileExtension: "pkg") { [weak self] fraction in
            Task { @MainActor [weak self] in
                self?.state = .downloading(progress: fraction)
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            let session = URLSession(
                configuration: .default,
                delegate: delegate,
                delegateQueue: nil
            )
            let task = session.downloadTask(with: url)
            self.activeDownloadTask = task
            task.resume()
        }
    }

    private func parseChecksum(text: String, filename: String) -> String? {
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasSuffix(filename) else { continue }
            // Format: "hash  filename" or "hash filename"
            let parts = trimmed.split(separator: " ", maxSplits: 1)
            guard let hash = parts.first else { continue }
            return String(hash)
        }
        return nil
    }

    private func expandPackage(pkgPath: URL, destination: URL) async throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
        proc.arguments = ["--expand-full", pkgPath.path, destination.path]

        let errPipe = Pipe()
        proc.standardError = errPipe

        try proc.run()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "Unknown error"
            throw UpdateError.extractionFailed(errMsg)
        }
    }

    private func findBinary(in expandedPkg: URL) -> URL? {
        let fm = FileManager.default

        // Expected layout from the thane .pkg:
        // <expanded>/thane-component.pkg/Payload/Thane/bin/thane
        let expected = expandedPkg.appending(
            components: "thane-component.pkg", "Payload", "Thane", "bin", "thane"
        )
        if fm.fileExists(atPath: expected.path) { return expected }

        // Fallback: search Payload directories for a file named "thane"
        guard let contents = try? fm.contentsOfDirectory(atPath: expandedPkg.path) else { return nil }
        for entry in contents where entry.hasSuffix(".pkg") {
            let payload = expandedPkg.appending(components: entry, "Payload")
            if let found = findExecutable(named: "thane", under: payload) {
                return found
            }
        }
        return nil
    }

    private func findExecutable(named name: String, under directory: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent == name {
            return url
        }
        return nil
    }

    // MARK: - Private: GitHub API

    private struct GitHubReleaseResponse: Decodable {
        let tagName: String
        let htmlUrl: String
        let body: String?
        let draft: Bool
        let prerelease: Bool
        let publishedAt: String
        let assets: [GitHubAsset]

        var isPreRelease: Bool { prerelease }

        var htmlURL: URL { URL(string: htmlUrl)! }

        var publishedDate: Date {
            let formatter = ISO8601DateFormatter()
            return formatter.date(from: publishedAt) ?? Date()
        }

        var assetURL: URL? {
            assets.first { $0.name.hasSuffix(UpdateManager.platformSuffix) }
                .flatMap { URL(string: $0.browserDownloadUrl) }
        }

        var checksumURL: URL? {
            assets.first { $0.name.hasSuffix("_checksums.txt") }
                .flatMap { URL(string: $0.browserDownloadUrl) }
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlUrl = "html_url"
            case body
            case draft
            case prerelease
            case publishedAt = "published_at"
            case assets
        }
    }

    private struct GitHubAsset: Decodable {
        let name: String
        let browserDownloadUrl: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadUrl = "browser_download_url"
        }
    }

    private func fetchLatestRelease() async throws -> GitHubReleaseResponse {
        let url: URL
        if includePreReleases {
            url = URL(string: "https://api.github.com/repos/\(Self.repoOwner)/\(Self.repoName)/releases")!
        } else {
            url = URL(string: "https://api.github.com/repos/\(Self.repoOwner)/\(Self.repoName)/releases/latest")!
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse {
            if let remaining = http.value(forHTTPHeaderField: "X-RateLimit-Remaining"),
               let count = Int(remaining), count == 0 {
                logger.warning("GitHub API rate limit exhausted")
                throw UpdateError.rateLimited
            }
            guard (200...299).contains(http.statusCode) else {
                throw UpdateError.httpError(statusCode: http.statusCode)
            }
        }

        let decoder = JSONDecoder()
        if includePreReleases {
            let releases = try decoder.decode([GitHubReleaseResponse].self, from: data)
            guard let first = releases.first(where: { !$0.draft }) else {
                throw UpdateError.noReleasesFound
            }
            return first
        } else {
            return try decoder.decode(GitHubReleaseResponse.self, from: data)
        }
    }
}

// MARK: - Errors

enum UpdateError: LocalizedError {
    case checksumParseFailure
    case checksumNotFound(filename: String)
    case checksumMismatch
    case binaryNotFoundInArchive
    case extractionFailed(String)
    case rateLimited
    case httpError(statusCode: Int)
    case noReleasesFound

    var errorDescription: String? {
        switch self {
        case .checksumParseFailure:
            return "Failed to parse checksum file"
        case .checksumNotFound(let f):
            return "No checksum entry for \(f)"
        case .checksumMismatch:
            return "SHA-256 checksum verification failed"
        case .binaryNotFoundInArchive:
            return "Could not locate thane binary in archive"
        case .extractionFailed(let msg):
            return "Archive extraction failed: \(msg)"
        case .rateLimited:
            return "GitHub API rate limit exceeded \u{2014} try again later"
        case .httpError(let code):
            return "GitHub API returned HTTP \(code)"
        case .noReleasesFound:
            return "No releases found"
        }
    }
}

