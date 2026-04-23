import CryptoKit
import Foundation

/// Shared checksum helpers used by both the binary updater and the app
/// self-updater. Kept nonisolated and dependency-free so they can be driven
/// from background tasks without actor hops.
enum Checksum {

    /// Stream a file through SHA-256 in 1 MiB chunks so we don't load
    /// multi-hundred-MB DMGs or pkgs into memory to verify them.
    nonisolated static func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        let chunkSize = 1 << 20 // 1 MiB
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Parse a standard `shasum`/`sha256sum` checksum file and return the
    /// hash for an exact filename match.
    ///
    /// Accepts both text-mode lines (`<hash>  <name>`) and binary-mode lines
    /// (`<hash> *<name>`). Tolerates leading `./` and any amount of internal
    /// whitespace. Requires an exact filename equality so a file named
    /// `foo.dmg` can't accidentally match a checksum entry for `evil_foo.dmg`.
    nonisolated static func parseChecksum(text: String, filename: String) -> String? {
        for line in text.components(separatedBy: .newlines) {
            if let hash = parseLine(line, filename: filename) { return hash }
        }
        return nil
    }

    nonisolated static func parseLine(_ line: String, filename: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(
            maxSplits: 1,
            omittingEmptySubsequences: true,
            whereSeparator: \.isWhitespace
        )
        guard parts.count == 2 else { return nil }

        let hash = String(parts[0])
        var entryName = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        if entryName.hasPrefix("*") { entryName.removeFirst() }           // binary-mode marker
        if entryName.hasPrefix("./") { entryName.removeFirst(2) }          // some tools prefix with ./

        return entryName == filename ? hash : nil
    }
}
