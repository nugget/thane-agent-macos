import Foundation
import Testing
@testable import thane_agent_macos

struct SemanticVersionTests {

    // MARK: - Parsing: plain SemVer

    @Test
    func parsesPlainVersion() {
        let v = SemanticVersion("1.2.3")
        #expect(v?.major == 1)
        #expect(v?.minor == 2)
        #expect(v?.patch == 3)
        #expect(v?.preRelease == nil)
        #expect(v?.commitsAhead == 0)
        #expect(v?.buildHash == nil)
    }

    @Test
    func parsesVersionWithVPrefix() {
        let v = SemanticVersion("v0.9.1")
        #expect(v?.major == 0)
        #expect(v?.minor == 9)
        #expect(v?.patch == 1)
        #expect(v?.preRelease == nil)
    }

    @Test
    func parsesPreReleaseTag() {
        let v = SemanticVersion("1.2.3-rc1")
        #expect(v?.preRelease == "rc1")
        #expect(v?.commitsAhead == 0)
    }

    @Test
    func parsesDottedPreReleaseTag() {
        let v = SemanticVersion("1.2.3-beta.4")
        #expect(v?.preRelease == "beta.4")
    }

    // MARK: - Parsing: git describe

    @Test
    func parsesGitDescribeFormat() {
        // The exact string from the bug report.
        let v = SemanticVersion("v0.9.1-71-g9d0c328")
        #expect(v?.major == 0)
        #expect(v?.minor == 9)
        #expect(v?.patch == 1)
        #expect(v?.preRelease == nil)
        #expect(v?.commitsAhead == 71)
        #expect(v?.buildHash == "9d0c328")
    }

    @Test
    func parsesGitDescribeFromPreRelease() {
        // 71 commits ahead of v1.2.3-rc1 — both pre-release and
        // commits-ahead suffixes coexist.
        let v = SemanticVersion("1.2.3-rc1-71-g9d0c328")
        #expect(v?.preRelease == "rc1")
        #expect(v?.commitsAhead == 71)
        #expect(v?.buildHash == "9d0c328")
    }

    @Test
    func parsesGitDescribeWithShortHash() {
        // Git auto-shortens hashes; 4 hex chars is the floor.
        let v = SemanticVersion("v1.2.3-1-gabcd")
        #expect(v?.commitsAhead == 1)
        #expect(v?.buildHash == "abcd")
    }

    @Test
    func ignoresTrailingSegmentsAfterGitDescribePair() {
        // Trailing "-dirty" markers are dropped — they're build metadata.
        let v = SemanticVersion("v0.9.1-71-g9d0c328-dirty")
        #expect(v?.commitsAhead == 71)
        #expect(v?.buildHash == "9d0c328")
        #expect(v?.preRelease == nil)
    }

    @Test
    func rejectsMalformedVersions() {
        #expect(SemanticVersion("not.a.version") == nil)
        #expect(SemanticVersion("1.2") == nil)
        #expect(SemanticVersion("1.2.3.4") == nil)
        #expect(SemanticVersion("") == nil)
    }

    // MARK: - Comparison: git-describe (the bug)

    @Test
    func gitDescribeBuildIsNewerThanPlainTag() {
        // Regression for the reported bug: a dev build 71 commits
        // ahead of v0.9.1 was being parsed as a SemVer pre-release
        // tag, sorting BELOW v0.9.1 and triggering a bogus "upgrade
        // to 0.9.1" prompt.
        let dev = SemanticVersion("v0.9.1-71-g9d0c328")!
        let tagged = SemanticVersion("v0.9.1")!
        #expect(dev > tagged)
        #expect(tagged < dev)
        #expect(!(dev <= tagged))
    }

    @Test
    func moreCommitsAheadIsNewer() {
        let earlier = SemanticVersion("0.9.1-10-gabc1234")!
        let later = SemanticVersion("0.9.1-71-g9d0c328")!
        #expect(earlier < later)
    }

    @Test
    func gitDescribeBuildIsOlderThanNextRelease() {
        // 71 commits ahead of v0.9.1 is still older than v0.9.2 —
        // the major.minor.patch comparison fires first.
        let dev = SemanticVersion("v0.9.1-71-g9d0c328")!
        let next = SemanticVersion("v0.9.2")!
        #expect(dev < next)
    }

    // MARK: - Comparison: SemVer pre-release (preserve existing behavior)

    @Test
    func preReleaseSortsBelowStable() {
        let rc = SemanticVersion("0.9.1-rc1")!
        let stable = SemanticVersion("0.9.1")!
        #expect(rc < stable)
        #expect(stable > rc)
    }

    @Test
    func preReleaseTagsCompareLexically() {
        let alpha = SemanticVersion("1.0.0-alpha")!
        let beta = SemanticVersion("1.0.0-beta")!
        #expect(alpha < beta)
    }

    @Test
    func majorMinorPatchTakePrecedenceOverPreRelease() {
        let oldStable = SemanticVersion("1.0.0")!
        let newPre = SemanticVersion("1.0.1-alpha")!
        #expect(oldStable < newPre)
    }

    @Test
    func gitDescribeOffPreReleaseIsNewerThanThatPreRelease() {
        // 71 commits past v1.2.3-rc1 should be newer than v1.2.3-rc1
        // itself (both share the rc1 pre-release tag, commitsAhead breaks
        // the tie).
        let pre = SemanticVersion("1.2.3-rc1")!
        let dev = SemanticVersion("1.2.3-rc1-71-g9d0c328")!
        #expect(pre < dev)
    }

    // MARK: - Equality: build hash is metadata only

    @Test
    func buildHashDoesNotAffectEquality() {
        // SemVer 2.0.0 §10: build metadata is ignored for precedence.
        let a = SemanticVersion("0.9.1-71-g9d0c328")!
        let b = SemanticVersion("0.9.1-71-gdeadbee")!
        #expect(a == b)
        #expect(!(a < b))
        #expect(!(b < a))
    }

    @Test
    func differentCommitCountsAreNotEqual() {
        let a = SemanticVersion("0.9.1-10-gabc1234")!
        let b = SemanticVersion("0.9.1-71-g9d0c328")!
        #expect(a != b)
    }

    // MARK: - Description round-trip

    @Test
    func descriptionRoundTripsPlainVersion() {
        #expect(SemanticVersion("1.2.3")!.description == "1.2.3")
    }

    @Test
    func descriptionRoundTripsPreRelease() {
        #expect(SemanticVersion("1.2.3-rc1")!.description == "1.2.3-rc1")
    }

    @Test
    func descriptionRoundTripsGitDescribe() {
        #expect(SemanticVersion("v0.9.1-71-g9d0c328")!.description == "0.9.1-71-g9d0c328")
    }

    @Test
    func descriptionRoundTripsGitDescribeOffPreRelease() {
        #expect(
            SemanticVersion("1.2.3-rc1-71-g9d0c328")!.description == "1.2.3-rc1-71-g9d0c328"
        )
    }
}
