# AGENTS.md

Welcome. thane-agent-macos is the native macOS companion app for
[Thane](https://github.com/nugget/thane-ai-agent) — a signed, notarized
SwiftUI app that installs and supervises the `thane` agent on a Mac,
provides the operator UI (menu bar, chat, dashboard, Process Health),
and hosts platform service providers that expose Apple frameworks to the
agent.

If you're here to understand the project, start with [README.md](README.md).

Everything below is what you need to contribute code.

## Build & Test

All workflows go through [just](https://just.systems/). Never call
`xcodebuild` directly — the justfile handles signing overrides, version
derivation from git, and release engineering.

```bash
just build              # Build for current platform
just ci                 # Full CI gate: build + test (run before every push)
just test               # Tests only (Swift Testing)
just marketing-version  # Derive version from nearest git tag
just build-number       # Derive build number from commit count
```

`just ci` must pass locally before every push. No exceptions. Don't rely
on GitHub Actions to catch what you could have caught locally. CI runs
on the `macos-26` runner with Xcode 26; local is Xcode 26+ on Apple
Silicon.

## Code Conventions

- **Swift 6** with strict concurrency. SwiftUI + `@Observable` (no
  Combine). SwiftData for persistence.
- **No third-party dependencies.** Everything uses system frameworks.
  Don't add dependencies without discussing the trade-off.
- **Conventional commits**: `feat:`, `fix:`, `docs:`, `refactor:`,
  `test:`, `chore:`.
- **Concurrency discipline**:
  - `@MainActor` types **must not do blocking work on the main actor**.
    Offload file I/O, CPU-heavy crypto, `Process.waitUntilExit`, SQLite,
    and similar to a detached `Task`. `MainActor` only touches `state`
    and the `@Observable` surface.
  - Shared helpers should be `nonisolated static` so they're callable
    from any isolation context without actor hops.
  - URL session delegates and other AppKit/Foundation bridges that
    can't be proven `Sendable` may be marked `@unchecked Sendable` —
    but only when the serialization model is explicit (e.g., URLSession
    guarantees its delegate queue is serial).
  - Xcode 26 (local) is more lenient than Xcode 16.4 era (CI). If a
    build passes locally but not in CI, the fix is almost always an
    explicit `nonisolated`, `@MainActor`, or `@unchecked Sendable`
    annotation — not a looser setting.
- **File I/O with unbounded size**: Never load user-facing downloads
  via `Data(contentsOf:)` for hashing, parsing, or transformation.
  DMGs and pkgs can be hundreds of MB. Stream via `FileHandle` in
  fixed-size chunks (1 MiB is a good default).
- **Exact-match for security-relevant strings**: Checksum entries,
  signing identities, release asset names, bundle identifiers — compare
  with equality, not `hasSuffix`/`hasPrefix`/`contains`. A filename
  match that accepts `evil_foo.dmg` for `foo.dmg` is a real attack
  vector; the same class of bug shows up in signing identity parsing,
  URL allowlists, etc.
- **Shared utilities over duplication**: Two call sites need the same
  parser, downloader, or process wrapper → extract to a shared file
  before the second copy. Common helpers live under `LocalServer/`.
- **Tests for pure helpers**: Parsers, selectors, anything
  side-effect-free that handles external input (checksum files, semver
  strings, release JSON, WebSocket message envelopes) gets Swift
  Testing coverage. Network-wrapped callers don't need tests, but the
  helpers they call do. Baseline: one test per format variant + one
  negative case.
- **Error handling**: Explicit. No silent swallow. `try?` does **not**
  catch Objective-C exceptions — CoreData/SwiftData fault failures
  throw `NSException` that bypass Swift's error handling. Use an ObjC
  exception-catcher bridge if you need to survive them.
- **Logging**: `os.Logger` with
  `subsystem: "info.nugget.thane-agent-macos"` and a specific category
  (`update`, `binary`, `connection`, etc.). No `print()` in committed
  code.
- **Dependency injection**: Environment-based via `AppState`. Don't
  reach for singletons.
- **Match existing patterns** before introducing new ones. Read the
  surrounding code; this is a small codebase where consistency matters.

## Architecture at a Glance

- **App entry / windows** — `ThaneApp.swift` (scene declarations,
  ModelContainer), `AppState.swift` (central `@Observable` coordinator)
- **Connection** — `ServerConnection.swift` (WebSocket client with auth
  handshake; uses `wss://` scheme to force HTTP/1.1 upgrade for Traefik
  compatibility)
- **Platform services** — `PlatformServiceRouter.swift` dispatches
  requests to registered providers; `CalendarService` is the only one
  shipping today
- **Local server** — `BinaryManager.swift` (thane process lifecycle,
  code-signature inspection), `UpdateManager.swift` (binary updates
  from thane-ai-agent releases)
- **Models** — SwiftData: `ServerConfig`, `Conversation`, `ChatMessage`.
  Store is bundle-scoped at
  `~/Library/Application Support/<bundle-id>/Data.store`
- **About / build provenance** — `AppVersion.swift` reads compile-time
  constants from `BuildInfo.swift` (stamped by `just stamp` from
  `git describe`)

## Releases

- Tag → DMG via `just release VERSION`. Driven locally on the release
  workstation — signing identity and notary profile live in the
  operator's keychain.
- Git tag is the single source of truth for `MARKETING_VERSION` (nearest
  tag) and `CURRENT_PROJECT_VERSION` (commit count). pbxproj values are
  fallbacks used only by bare Xcode IDE opens.
- DMG is signed + notarized + stapled; so is the .app inside.
- Pre-release tags (e.g. `v0.2.0-rc.1`) auto-detected as GitHub
  prereleases.
- Release notes are auto-generated by `gh release create --generate-notes`
  from merged PRs and commits since the previous tag. The
  [Releases page](https://github.com/nugget/thane-agent-macos/releases)
  is the source of truth for release history.

## Gotchas

- **SwiftData default store**: Non-sandboxed apps get
  `~/Library/Application Support/default.store` if you don't specify a
  URL. That path is shared with every other SwiftData app on the
  machine and accumulates persistent-history state across schema
  iterations — which can cause `_PFFaultHandlerLookupRow` crashes in
  `modelContext.save()`. Always use a bundle-scoped
  `ModelConfiguration(url:)` — see `ThaneApp.swift`.
- **Xcode 26 vs CI**: Local is lenient, CI is strict. If it compiles
  for you and not for CI, you need concurrency annotations.
- **Objective-C exceptions**: `try?` doesn't catch them. Plan
  accordingly when working with CoreData, AppKit, or NSNotification
  paths that can throw.
- **Signing identity env vars**: `THANE_CODESIGN_IDENTITY`,
  `THANE_NOTARY_PROFILE`. Names match the thane-ai-agent release
  scripts so one `.env` can drive both projects.
- **Entitlements**: Only `com.apple.security.personal-information.calendars`
  today. Add sparingly — each new entitlement is another permission
  dialog for operators.
- **`ExportOptions.plist` is generated**, not committed. The team ID is
  parsed from `THANE_CODESIGN_IDENTITY` at export time.
- **macOS Local Network Privacy**: launchd-launched binaries need
  explicit Local Network permission to reach LAN hosts.

## Security

- **Developer ID signed and notarized** — every release DMG and the
  .app inside. No ad-hoc signing for distribution.
- **Hardened runtime** enabled.
- **API tokens** in Keychain, never UserDefaults. Keyed by
  `ServerConfig`.
- **TLS verification** never disabled.
- **Release credentials** stay on the release workstation (keychain
  profile for notarytool, signing cert in login keychain). No
  GitHub-hosted signing.

## Contributing

### Issues

File bugs and feature requests with enough detail to reproduce: what's
happening, what should happen, and what you've already ruled out.

### Pull Requests

- **All commits must be signed.** PRs with unsigned commits won't merge
  (branch protection).
- **Never push directly to main.** Always branch and PR.
- Run `just ci` locally before pushing.
- Keep PRs focused — one logical change per PR.
- Conventional commit format for titles and commits.
- Reference issues: `Refs #NNN` or `Closes #NNN` in commit bodies.
- **Update docs in the same PR** when you change documented behavior
  (AGENTS.md, CLAUDE.md, README). Doc drift is worse than
  no doc.

### Common Review Feedback

Getting these right on the first pass saves a round trip:

- **Main-actor blocking work** — Any `@MainActor` method doing file
  I/O, hashing, or `Process.waitUntilExit` needs to offload to a
  detached `Task`.
- **Loading large files whole** — Hashing a DMG via `Data(contentsOf:)`
  blows up memory. Stream via `FileHandle` with a chunk loop.
- **Loose string matching** — `hasSuffix("foo.dmg")` accepts
  `evil_foo.dmg`. Use exact equality for security-relevant inputs.
- **Missing tests** — Pure parsers and selectors need Swift Testing
  coverage. One test per format variant, one negative case.
- **Swift 6 annotations** — If it compiles locally but fails CI, you
  need `nonisolated`, `@MainActor`, or `@unchecked Sendable` — not a
  looser setting.
- **Duplicated helper logic** — Two managers doing the same parsing or
  the same download dance → extract to a shared file.

### Review Culture

Leave PRs clean and reflective of reality. Open threads, stale
descriptions, and unchecked test-plan items signal unfinished work.

When addressing feedback: fix the issue, reply with the commit hash and
a one-line explanation, then resolve the thread. If deferring (out of
scope, follow-up issue), say so explicitly before resolving.

## Further Reading

- [README.md](README.md) — User-facing project overview
- [Releases](https://github.com/nugget/thane-agent-macos/releases) — Tagged builds with auto-generated notes
- [Thane (Go agent)](https://github.com/nugget/thane-ai-agent) — The
  backend this app pairs with
- [Thane docs](https://github.com/nugget/thane-ai-agent/tree/main/docs) —
  Philosophy, architecture, configuration, deployment
