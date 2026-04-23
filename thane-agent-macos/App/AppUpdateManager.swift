import AppKit
import CryptoKit
import Foundation
import os

// MARK: - Available App Release

struct AvailableAppRelease: Sendable {
    let version: SemanticVersion
    let tagName: String
    let dmgURL: URL
    let checksumURL: URL
    let htmlURL: URL
    let isPreRelease: Bool
    let publishedAt: Date
    let changelog: String?
}

// MARK: - App Update State

enum AppUpdateState: Equatable {
    case idle
    case checking
    case available(version: String)
    case downloading(progress: Double)
    case verifying
    case installing
    case failed(message: String)
}

// MARK: - App Update Manager

/// Self-update driver for thane-agent-macos. Polls the app's GitHub releases,
/// downloads and verifies the signed DMG, then hands off to a detached shell
/// helper that waits for the running process to exit, swaps the bundle at
/// `Bundle.main.bundleURL`, and relaunches.
///
/// Parallels `UpdateManager` (which updates the `thane` binary) — same release
/// polling model, same auto-check cadence, same `.available → .installing`
/// state machine. The install mechanism differs because a live app can't
/// replace its own bundle, so we bounce through a child process.
@Observable
@MainActor
final class AppUpdateManager {

    private(set) var state: AppUpdateState = .idle
    private(set) var availableRelease: AvailableAppRelease?

    var autoUpdateEnabled: Bool {
        didSet { UserDefaults.standard.set(autoUpdateEnabled, forKey: "appAutoUpdateEnabled") }
    }
    var includePreReleases: Bool {
        didSet { UserDefaults.standard.set(includePreReleases, forKey: "appUpdateIncludePreReleases") }
    }
    private(set) var lastCheckDate: Date? {
        didSet {
            if let d = lastCheckDate {
                UserDefaults.standard.set(d.timeIntervalSince1970, forKey: "appUpdateLastCheckDate")
            }
        }
    }

    private let logger = Logger(subsystem: "info.nugget.thane-agent-macos", category: "app-update")
    private var periodicCheckTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var activeDownloadTask: URLSessionDownloadTask?

    private static let repoOwner = "nugget"
    private static let repoName = "thane-agent-macos"
    private static let checkIntervalSeconds: TimeInterval = 86400 // 24 hours

    init() {
        autoUpdateEnabled = UserDefaults.standard.bool(forKey: "appAutoUpdateEnabled")
        includePreReleases = UserDefaults.standard.bool(forKey: "appUpdateIncludePreReleases")
        let ts = UserDefaults.standard.double(forKey: "appUpdateLastCheckDate")
        lastCheckDate = ts > 0 ? Date(timeIntervalSince1970: ts) : nil
    }

    // MARK: - Check

    func checkForUpdate(currentVersion: String?) async {
        state = .checking
        availableRelease = nil

        do {
            let release = try await fetchLatestRelease()
            lastCheckDate = Date()

            guard let dmgURL = release.dmgURL,
                  let checksumURL = release.checksumURL else {
                logger.warning("No DMG / checksums asset in release \(release.tagName)")
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

            let available = AvailableAppRelease(
                version: remoteVersion,
                tagName: release.tagName,
                dmgURL: dmgURL,
                checksumURL: checksumURL,
                htmlURL: release.htmlURL,
                isPreRelease: release.isPreRelease,
                publishedAt: release.publishedDate,
                changelog: release.body
            )
            availableRelease = available
            state = .available(version: remoteVersion.description)
            logger.info("App update available: \(remoteVersion)")
        } catch {
            logger.error("App update check failed: \(error.localizedDescription)")
            state = .failed(message: error.localizedDescription)
        }
    }

    // MARK: - Download + Install

    func downloadAndInstall() {
        guard let release = availableRelease, state == .available(version: release.version.description) else { return }

        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await performDownloadAndInstall(release: release)
            } catch is CancellationError {
                state = .available(version: release.version.description)
            } catch {
                logger.error("App update failed: \(error.localizedDescription)")
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

    private func performDownloadAndInstall(release: AvailableAppRelease) async throws {
        state = .downloading(progress: 0)
        let fm = FileManager.default

        let dmgFilename = release.dmgURL.lastPathComponent
        let tempFileURL = try await downloadFile(from: release.dmgURL)
        activeDownloadTask = nil
        try Task.checkCancellation()

        // Move into a work directory we own — tempFileURL may be cleaned up.
        let workDir = fm.temporaryDirectory.appending(component: "thane-app-update-\(UUID().uuidString)")
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        let dmgPath = workDir.appending(component: dmgFilename)
        try fm.moveItem(at: tempFileURL, to: dmgPath)

        // Verify SHA-256 against the checksums asset.
        state = .verifying
        let (checksumData, _) = try await URLSession.shared.data(from: release.checksumURL)
        try Task.checkCancellation()
        guard let checksumText = String(data: checksumData, encoding: .utf8) else {
            throw AppUpdateError.checksumParseFailure
        }
        guard let expectedHash = parseChecksum(text: checksumText, filename: dmgFilename) else {
            throw AppUpdateError.checksumNotFound(filename: dmgFilename)
        }
        let dmgData = try Data(contentsOf: dmgPath)
        let actualHash = SHA256.hash(data: dmgData).map { String(format: "%02x", $0) }.joined()
        guard actualHash == expectedHash else {
            logger.error("SHA-256 mismatch: expected \(expectedHash), got \(actualHash)")
            try? fm.removeItem(at: workDir)
            throw AppUpdateError.checksumMismatch
        }
        logger.info("SHA-256 verified for \(dmgFilename)")

        // Verify the DMG is signed + notarized — spctl returns non-zero if not.
        try assertGatekeeperAccepts(dmgPath: dmgPath)

        // Hand off to the helper. The helper waits for us to exit, swaps the
        // bundle, and relaunches — so this is our last step before terminate.
        state = .installing
        let installPath = Bundle.main.bundleURL
        let scriptPath = try writeRelaunchHelper(workDir: workDir)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [
            scriptPath.path,
            String(ProcessInfo.processInfo.processIdentifier),
            dmgPath.path,
            installPath.path,
            workDir.path,
        ]
        try task.run()

        // Give the helper a tick to get into its wait loop, then quit ourselves.
        try? await Task.sleep(for: .milliseconds(500))
        logger.info("Relinquishing to helper for bundle swap at \(installPath.path)")
        NSApp.terminate(nil)
    }

    private func downloadFile(from url: URL) async throws -> URL {
        let delegate = DownloadDelegate(tempFileExtension: "dmg") { [weak self] fraction in
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
            let parts = trimmed.split(separator: " ", maxSplits: 1)
            guard let hash = parts.first else { continue }
            return String(hash)
        }
        return nil
    }

    private func assertGatekeeperAccepts(dmgPath: URL) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/spctl")
        proc.arguments = ["--assess", "--type", "open", "--context", "context:primary-signature", dmgPath.path]

        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()

        try proc.run()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "unknown"
            logger.error("Gatekeeper rejected DMG: \(errMsg)")
            throw AppUpdateError.gatekeeperRejected(errMsg)
        }
        logger.info("Gatekeeper accepted DMG")
    }

    /// Writes a shell helper that waits for the running app to exit, then
    /// mounts the DMG, swaps the bundle, relaunches, and cleans up.
    private func writeRelaunchHelper(workDir: URL) throws -> URL {
        let script = #"""
            #!/bin/sh
            # Arguments: <parent-pid> <dmg-path> <install-path> <work-dir>
            set -u

            PID="$1"
            DMG="$2"
            INSTALL="$3"
            WORK="$4"

            LOG="$WORK/relaunch.log"
            exec >> "$LOG" 2>&1
            echo "[$(date)] relaunch helper started pid=$$ target=$INSTALL"

            # Wait for the parent app to exit.
            while kill -0 "$PID" 2>/dev/null; do
                sleep 0.5
            done
            echo "[$(date)] parent $PID gone, mounting DMG"

            MOUNT="$WORK/mount"
            mkdir -p "$MOUNT"
            if ! hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$MOUNT"; then
                echo "[$(date)] ERROR: hdiutil attach failed" >&2
                open -R "$DMG"
                exit 1
            fi

            APP_NAME=$(basename "$INSTALL")
            SRC="$MOUNT/$APP_NAME"
            if [ ! -d "$SRC" ]; then
                echo "[$(date)] ERROR: $APP_NAME not present in DMG" >&2
                hdiutil detach "$MOUNT" -force >/dev/null 2>&1
                open -R "$DMG"
                exit 1
            fi

            TRASH="$WORK/$APP_NAME.old"
            echo "[$(date)] moving old bundle aside to $TRASH"
            if [ -e "$INSTALL" ]; then
                if ! mv "$INSTALL" "$TRASH"; then
                    echo "[$(date)] ERROR: could not move $INSTALL aside (permissions?)" >&2
                    hdiutil detach "$MOUNT" -force >/dev/null 2>&1
                    open -R "$DMG"
                    exit 1
                fi
            fi

            echo "[$(date)] copying new bundle to $INSTALL"
            if ! ditto "$SRC" "$INSTALL"; then
                echo "[$(date)] ERROR: ditto failed — restoring previous" >&2
                mv "$TRASH" "$INSTALL" 2>/dev/null || true
                hdiutil detach "$MOUNT" -force >/dev/null 2>&1
                exit 1
            fi

            # Clear the downloaded-from-Internet quarantine so Gatekeeper doesn't
            # nag — the app was already notarization-verified by spctl above.
            xattr -dr com.apple.quarantine "$INSTALL" 2>/dev/null || true

            hdiutil detach "$MOUNT" -force >/dev/null 2>&1
            rm -rf "$TRASH"

            echo "[$(date)] launching new bundle"
            open "$INSTALL"

            # Best-effort cleanup — the workdir under /tmp will get reaped on reboot anyway.
            sleep 2
            rm -f "$DMG"
            exit 0
            """#

        let url = workDir.appending(component: "relaunch.sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
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

        var dmgURL: URL? {
            assets.first { $0.name.hasSuffix(".dmg") }
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
                throw AppUpdateError.rateLimited
            }
            guard (200...299).contains(http.statusCode) else {
                throw AppUpdateError.httpError(statusCode: http.statusCode)
            }
        }

        let decoder = JSONDecoder()
        if includePreReleases {
            let releases = try decoder.decode([GitHubReleaseResponse].self, from: data)
            guard let first = releases.first(where: { !$0.draft }) else {
                throw AppUpdateError.noReleasesFound
            }
            return first
        } else {
            return try decoder.decode(GitHubReleaseResponse.self, from: data)
        }
    }
}

// MARK: - Errors

enum AppUpdateError: LocalizedError {
    case checksumParseFailure
    case checksumNotFound(filename: String)
    case checksumMismatch
    case gatekeeperRejected(String)
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
        case .gatekeeperRejected(let msg):
            return "Gatekeeper rejected the update: \(msg)"
        case .rateLimited:
            return "GitHub API rate limit exceeded \u{2014} try again later"
        case .httpError(let code):
            return "GitHub API returned HTTP \(code)"
        case .noReleasesFound:
            return "No releases found"
        }
    }
}
