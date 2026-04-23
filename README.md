# thane-agent-macos

[![CI](https://github.com/nugget/thane-agent-macos/actions/workflows/ci.yml/badge.svg)](https://github.com/nugget/thane-agent-macos/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/nugget/thane-agent-macos?include_prereleases)](https://github.com/nugget/thane-agent-macos/releases/latest)
[![License](https://img.shields.io/github/license/nugget/thane-agent-macos)](LICENSE)
[![macOS](https://img.shields.io/badge/macOS-26%2B-blue)](https://www.apple.com/macos/)

> Native macOS companion app for [Thane](https://github.com/nugget/thane-ai-agent).

Thane is an autonomous AI agent that runs on your hardware. This is the Mac side of the story: a signed, notarized SwiftUI app that **connects your Mac to a running Thane instance** as both a chat client and a platform service provider. It brings your Calendar, Contacts, Reminders, Focus, and Shortcuts into the agent's reach through native frameworks — no CardDAV scraping, no ICS polling, no cloud hop.

It also manages the `thane` binary on the Mac itself: auto-discovers existing installs, downloads signed updates from GitHub releases, verifies SHA-256 checksums, inspects code signatures, and keeps the local server healthy.

## Why it exists

**Native framework access.** Home Assistant integrations for Contacts, Calendar, and Reminders go through network scraping — CardDAV, CalDAV, ICS. This app hands the agent direct, first-class access to Apple's own frameworks on your Mac, which is both faster and correct.

**Chat anywhere on the Mac.** Menu bar presence with live connection status. A Dashboard window for conversation history. No browser tab required.

**Trustworthy binary management.** The in-app updater fetches Thane releases, verifies notarization and checksums, stops and restarts the local process atomically, and surfaces code signing info in Process Health so you can see exactly what's running.

**Mac-native at every level.** Hardened runtime. Developer ID signed. Notarized by Apple. Built with SwiftUI and `@Observable`, SwiftData for persistence, Security.framework for signature inspection — no third-party dependencies. One `.dmg`, drag to Applications, done.

## Quick Start

### Install

Download the latest signed `.dmg` from the [Releases page](https://github.com/nugget/thane-agent-macos/releases/latest) and drag the app into Applications.

The app self-updates the `thane` binary on first launch — point it at your running [Thane](https://github.com/nugget/thane-ai-agent) server and you're set.

### Build from source

Requires Xcode 26+ and [just](https://github.com/casey/just).

```bash
git clone https://github.com/nugget/thane-agent-macos.git
cd thane-agent-macos
just build
```

The full CI gate runs via `just ci` (build + tests). See [CLAUDE.md](CLAUDE.md) for project conventions.

## Releases

Tagged releases publish a signed, notarized, stapled `.dmg` plus a SHA-256
checksums file to GitHub. The release workstation drives the whole pipeline
locally — signing identity and notary profile stay in the operator's
keychain — and the macOS app itself manages updates for the `thane` binary
via GitHub's release API on its own.

- `just release 0.1.0` — cut a formal release (tag, DMG, notarize, staple, upload)
- `just release 0.2.0-rc.1` — auto-detected as a prerelease

See [CHANGELOG.md](CHANGELOG.md) for what's in each release.

## Architecture at a glance

- **App entry / windows** — `ThaneApp.swift`, `AppState.swift` (central `@Observable` coordinator)
- **Local server** — `BinaryManager.swift` (process lifecycle, code-signature inspection), `UpdateManager.swift` (GitHub release polling, download, verify, install)
- **Connection** — `ServerConnection.swift` (WebSocket client with auth handshake and platform request routing)
- **Platform services** — Native access to Contacts, Calendar, Reminders, Focus, and Shortcuts, routed over the same WebSocket
- **Chat** — SwiftUI chat view backed by SwiftData (`Conversation`, `ChatMessage`)
- **Process Health** — Live resource stats and code-signature summary for the running `thane` binary

## Related

- **[nugget/thane-ai-agent](https://github.com/nugget/thane-ai-agent)** — The Go agent this app connects to. Start there if you don't have a Thane running yet.
- **[Thane docs](https://github.com/nugget/thane-ai-agent/tree/main/docs)** — Philosophy, architecture, configuration, deployment
- **[WebSocket protocol design](https://github.com/nugget/thane-ai-agent/issues/627)** — The platform service contract this app implements

## License

Apache 2.0 — aligned with [Thane](https://github.com/nugget/thane-ai-agent) and Home Assistant.
