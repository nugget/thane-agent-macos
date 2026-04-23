import Foundation
import Testing
@testable import thane_agent_macos

struct ChecksumTests {

    // MARK: - parseChecksum

    @Test
    func parsesTwoSpaceFormat() {
        let line = "abc123  thane-agent-macos_0.1.0.dmg"
        #expect(Checksum.parseChecksum(text: line, filename: "thane-agent-macos_0.1.0.dmg") == "abc123")
    }

    @Test
    func parsesSingleSpaceFormat() {
        let line = "abc123 thane-agent-macos_0.1.0.dmg"
        #expect(Checksum.parseChecksum(text: line, filename: "thane-agent-macos_0.1.0.dmg") == "abc123")
    }

    @Test
    func parsesBinaryModeMarker() {
        let line = "abc123 *thane-agent-macos_0.1.0.dmg"
        #expect(Checksum.parseChecksum(text: line, filename: "thane-agent-macos_0.1.0.dmg") == "abc123")
    }

    @Test
    func parsesLeadingDotSlash() {
        let line = "abc123  ./thane-agent-macos_0.1.0.dmg"
        #expect(Checksum.parseChecksum(text: line, filename: "thane-agent-macos_0.1.0.dmg") == "abc123")
    }

    @Test
    func picksRightLineFromMultiLineFile() {
        let file = """
        aaa  thane_0.9.1_linux_amd64.tar.gz
        bbb  thane_0.9.1_linux_arm64.tar.gz
        ccc  thane_0.9.1_darwin_arm64.pkg
        ddd  thane_0.9.1_darwin_amd64.pkg
        """
        #expect(Checksum.parseChecksum(text: file, filename: "thane_0.9.1_darwin_arm64.pkg") == "ccc")
    }

    @Test
    func requiresExactFilenameMatch() {
        // A naive hasSuffix match would incorrectly pick up "evil_foo.dmg"
        // when asked for "foo.dmg". Exact match prevents that.
        let file = """
        badhash  evil_foo.dmg
        goodhash  foo.dmg
        """
        #expect(Checksum.parseChecksum(text: file, filename: "foo.dmg") == "goodhash")
    }

    @Test
    func returnsNilWhenFilenameMissing() {
        let file = "abc123  something-else.dmg"
        #expect(Checksum.parseChecksum(text: file, filename: "foo.dmg") == nil)
    }

    @Test
    func toleratesBlankAndWhitespaceOnlyLines() {
        let file = """

        abc123  thane-agent-macos_0.1.0.dmg

        """
        #expect(Checksum.parseChecksum(text: file, filename: "thane-agent-macos_0.1.0.dmg") == "abc123")
    }

    // MARK: - sha256 streaming

    @Test
    func sha256MatchesKnownVector() throws {
        // "abc" -> ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
        let tmp = FileManager.default.temporaryDirectory.appending(
            component: "thane-checksum-test-\(UUID().uuidString)"
        )
        try "abc".data(using: .utf8)!.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let hash = try Checksum.sha256(of: tmp)
        #expect(hash == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test
    func sha256HandlesLargeMultiChunkFile() throws {
        // Write 5 MiB of zeros — exercises the streaming loop (chunk = 1 MiB).
        let tmp = FileManager.default.temporaryDirectory.appending(
            component: "thane-checksum-test-\(UUID().uuidString)"
        )
        let payload = Data(count: 5 * 1024 * 1024)
        try payload.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Expected: SHA-256 of 5 MiB of 0x00 (from `dd if=/dev/zero bs=1m count=5 | shasum -a 256`).
        let expected = "c036cbb7553a909f8b8877d4461924307f27ecb66cff928eeeafd569c3887e29"
        let hash = try Checksum.sha256(of: tmp)
        #expect(hash == expected)
    }

    @Test
    func sha256HandlesEmptyFile() throws {
        let tmp = FileManager.default.temporaryDirectory.appending(
            component: "thane-checksum-test-\(UUID().uuidString)"
        )
        try Data().write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        #expect(try Checksum.sha256(of: tmp) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }
}
