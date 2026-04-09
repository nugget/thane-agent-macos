# CLAUDE.md

macOS companion app for [thane-ai-agent](https://github.com/nugget/thane-ai-agent).
Swift/SwiftUI, targets macOS on Apple Silicon.

## Build & Test

This project uses a `justfile`. Always use `just`, never call `xcodebuild` directly.

```bash
just build          # Debug build
just test           # Run unit + UI tests
just ci             # Full CI gate (build + test)
```

**MANDATORY: `just ci` must pass locally before every `git push`. No
exceptions.** Do not rely on GitHub Actions — run the full gate locally
first and fix any issues before pushing.

## Commit Signing

The SessionStart hook configures repo-local signing automatically each
session using Claude's dedicated key (see `~/.claude/CLAUDE.md` for
identity details). Verify signing is active before your first commit:

```bash
git config commit.gpgsign   # should return true
```

If signing fails, set it up manually:

```bash
git config --local user.name "Claude Code (nugget)"
git config --local user.email "claude@nugget.info"
git config --local user.signingkey "~/.claude/ssh/id_claude"
git config --local gpg.format ssh
git config --local commit.gpgsign true
git config --local gpg.ssh.allowedsignersfile "~/.claude/ssh/allowed_signers"
git config --local gpg.ssh.program ssh-keygen
```

## Architecture

- **ThaneApp.swift** — App entry, window definitions (Main, MenuBar, Settings, Process Health, Dashboard)
- **AppState.swift** — Central `@Observable` coordinator; owns `ServerConnection`, `BinaryManager`, `UpdateManager`, `PlatformServiceRouter`
- **BinaryManager.swift** — Local `thane` process lifecycle, health monitoring, config parsing, code signature inspection
- **UpdateManager.swift** — GitHub release checking, binary download/verify/install with SHA-256 + CryptoKit
- **CodeSignatureInfo.swift** — `AppleCodeSignature` (Security.framework) for code signing and notarization inspection
- **ServerConnection.swift** — WebSocket client with auth handshake and platform request routing
- **ProcessHealthView.swift** — Live process health status, resource stats, code signature summary
- Data models use SwiftData (`ServerConfig`, `Conversation`, `ChatMessage`)

## Conventions

- SwiftUI with `@Observable` (not Combine)
- Environment-based dependency injection via `AppState`
- No third-party dependencies — everything uses system frameworks
- Match existing patterns before introducing new ones
