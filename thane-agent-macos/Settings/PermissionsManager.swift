import Foundation
import os

/// Tracks per-category TCC permission state for paths that thane accesses.
///
/// Philosophy: never probe implicitly. The user opts in per-category via the
/// Permissions settings tab. Once a category has been requested, we silently
/// re-probe on settings-open to reflect any changes the user made in System Settings.
@Observable
@MainActor
final class PermissionsManager {

    // MARK: - Types

    enum Status: String, Sendable {
        case notRequested  // never probed — must not trigger a dialog implicitly
        case granted
        case denied
    }

    struct Category: Identifiable, Sendable {
        let id: String
        let name: String
        let description: String
        let paths: [URL]
        var status: Status = .notRequested
        var isCustom: Bool = false
    }

    // MARK: - State

    private(set) var categories: [Category]

    private let logger = Logger(subsystem: "info.nugget.thane-agent-macos", category: "permissions")

    // MARK: - Init

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser

        categories = [
            Category(
                id: "downloads",
                name: "Downloads",
                description: "Files saved from the web and other apps.",
                paths: [home.appending(path: "Downloads")]
            ),
            Category(
                id: "documents",
                name: "Documents",
                description: "Files in your Documents folder.",
                paths: [home.appending(path: "Documents")]
            ),
            Category(
                id: "desktop",
                name: "Desktop",
                description: "Files on the Desktop.",
                paths: [home.appending(path: "Desktop")]
            ),
            Category(
                id: "media",
                name: "Media",
                description: "Music, Movies, and Pictures libraries.",
                paths: [
                    home.appending(path: "Music"),
                    home.appending(path: "Movies"),
                    home.appending(path: "Pictures"),
                ]
            ),
            Category(
                id: "appdata",
                name: "Application Data",
                description: "Data stored by other installed apps (triggers 'data from other apps' permission).",
                paths: [
                    home.appending(path: "Library/Application Support"),
                    home.appending(path: "Library/Containers"),
                ]
            ),
        ]

        // Restore saved statuses for built-in categories
        for i in categories.indices {
            if let raw = UserDefaults.standard.string(forKey: statusKey(categories[i].id)),
               let status = Status(rawValue: raw) {
                categories[i].status = status
            }
        }

        // Restore custom locations
        let customPaths = UserDefaults.standard.stringArray(forKey: "customPermissionPaths") ?? []
        for path in customPaths {
            let url = URL(fileURLWithPath: path)
            var cat = Category(
                id: customCategoryID(for: url),
                name: url.lastPathComponent,
                description: url.deletingLastPathComponent().path,
                paths: [url],
                isCustom: true
            )
            if let raw = UserDefaults.standard.string(forKey: statusKey(cat.id)),
               let status = Status(rawValue: raw) {
                cat.status = status
            }
            categories.append(cat)
        }
    }

    // MARK: - Actions

    /// Probe all paths in the category, triggering a TCC dialog if macOS hasn't decided yet.
    /// Updates and persists the resulting status.
    func requestAccess(categoryID: String) async {
        guard let idx = categories.firstIndex(where: { $0.id == categoryID }) else { return }
        let paths = categories[idx].paths

        let status: Status = await Task.detached {
            let fm = FileManager.default
            var granted = 0
            var denied = 0
            for url in paths {
                do {
                    _ = try fm.contentsOfDirectory(atPath: url.path)
                    granted += 1
                } catch let error as NSError {
                    if error.code == NSFileReadNoPermissionError ||
                       error.code == NSFileReadUnknownError ||
                       (error.domain == NSPOSIXErrorDomain && error.code == Int(EPERM)) ||
                       (error.domain == NSPOSIXErrorDomain && error.code == Int(EACCES)) {
                        denied += 1
                    } else {
                        // Path doesn't exist (e.g. no ~/Movies) — not a permission failure
                        granted += 1
                    }
                }
            }
            return denied > 0 && granted == 0 ? .denied : .granted
        }.value

        logger.info("Permission \(categoryID): \(status.rawValue)")
        categories[idx].status = status
        UserDefaults.standard.set(status.rawValue, forKey: statusKey(categoryID))
    }

    /// Silently re-probe previously-requested categories. TCC remembers decisions,
    /// so this never surfaces a new dialog — it just refreshes displayed status.
    func refreshPreviouslyRequested() async {
        for category in categories where category.status != .notRequested {
            await requestAccess(categoryID: category.id)
        }
    }

    /// Add a user-chosen directory as a custom category.
    func addCustomLocation(_ url: URL) {
        let id = customCategoryID(for: url)
        guard !categories.contains(where: { $0.id == id }) else { return }

        let cat = Category(
            id: id,
            name: url.lastPathComponent,
            description: url.deletingLastPathComponent().path,
            paths: [url],
            isCustom: true
        )
        categories.append(cat)
        persistCustomPaths()
    }

    /// Remove a custom category.
    func removeCustomLocation(categoryID: String) {
        categories.removeAll { $0.id == categoryID && $0.isCustom }
        UserDefaults.standard.removeObject(forKey: statusKey(categoryID))
        persistCustomPaths()
    }

    // MARK: - Helpers

    private func statusKey(_ id: String) -> String { "perm_\(id)" }

    private func customCategoryID(for url: URL) -> String {
        "custom_\(url.path.hashValue)"
    }

    private func persistCustomPaths() {
        let paths = categories.filter(\.isCustom).map(\.paths).compactMap(\.first?.path)
        UserDefaults.standard.set(paths, forKey: "customPermissionPaths")
    }
}
