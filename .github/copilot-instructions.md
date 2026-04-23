# Copilot Instructions for thane-agent-macos

For full project conventions, see [AGENTS.md](../AGENTS.md).

## Build Notes

- Build via `just build`; never call `xcodebuild` directly
- CI uses the `macos-26` runner with Xcode 26; local is Xcode 26+
- Ad-hoc signing path for CI (`CODE_SIGNING_ALLOWED=NO`) lives in the
  justfile — don't work around it

## Review Focus

When reviewing or generating code, watch for:

- **`@MainActor` types doing blocking work** — file I/O, hashing,
  `Process.waitUntilExit`, SQLite. Offload to a detached `Task`.
- **`Data(contentsOf:)` on user-facing downloads** — DMGs and pkgs can
  be hundreds of MB. Stream via `FileHandle` with a chunk loop.
- **Loose string matching for security-relevant inputs** —
  `hasSuffix`/`hasPrefix`/`contains` where exact equality is required
  (checksum entries, signing identities, asset names). Use `==`.
- **Missing tests for pure helpers** — parsers, selectors, anything
  side-effect-free that handles external input needs Swift Testing
  coverage.
- **Swift 6 concurrency gaps** — if it compiles in Xcode 26 locally
  but CI (Xcode 26 too, but stricter builds) flags it, the fix is an
  explicit `nonisolated`, `@MainActor`, or `@unchecked Sendable`
  annotation — not a looser setting.
- **`try?` catching nothing useful** — Objective-C `NSException`
  bypasses Swift error handling. CoreData/SwiftData fault failures are
  a known hazard.
- **Duplicated helper logic** — two managers doing the same parsing,
  downloading, or process invocation → extract to a shared file.
- **New third-party dependencies** — flag them for discussion; this
  project intentionally sticks to system frameworks.

## Doc Hygiene

- Behavioral changes must update `AGENTS.md`, `CLAUDE.md`, or
  `README` in the same PR
- Doc drift is worse than missing docs
