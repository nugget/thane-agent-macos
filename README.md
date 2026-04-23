# thane-agent-macos

[![CI](https://github.com/nugget/thane-agent-macos/actions/workflows/ci.yml/badge.svg)](https://github.com/nugget/thane-agent-macos/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/nugget/thane-agent-macos?include_prereleases)](https://github.com/nugget/thane-agent-macos/releases/latest)
[![License](https://img.shields.io/github/license/nugget/thane-agent-macos)](LICENSE)
[![macOS](https://img.shields.io/badge/macOS-26%2B-blue)](https://www.apple.com/macos/)

> The supported way to run [Thane](https://github.com/nugget/thane-ai-agent) on macOS.

A signed, notarized SwiftUI companion app that makes running a Thane agent on a Mac straightforward: it installs and supervises the `thane` binary, gives you a native chat UI and menu bar presence, and lays the foundation for tight integration with the Apple applications ecosystem — Calendar, Contacts, Reminders, Focus modes, Shortcuts.

**If you want Thane on macOS, this is the recommended path.** You can still build and run the Go binary by hand, but the app handles the operational surface — install, updates, permissions, process health, and (in time) native platform integrations — so you don't have to.

**Status: early.** The WebSocket connection, chat UI, and Thane binary manager work end-to-end. Platform service providers are in active development — see [What's implemented](#whats-implemented) for the honest status.

## Why it exists

Running Thane well on a Mac involves more than compiling the Go binary:

- **Install and updates.** The app downloads signed `.pkg` releases from GitHub, verifies SHA-256 checksums and notarization, installs atomically, and supervises the local process.
- **Operator UI.** Menu bar, chat window, Process Health view with resource stats and code-signature inspection — no terminal required for day-to-day use.
- **Apple-ecosystem integration.** Calendar, Contacts, Focus, Reminders, and Shortcuts live behind Apple frameworks that aren't reachable from a Linux agent without lossy workarounds (CardDAV scraping, ICS polling). This app is the bridge that lets Thane reach into those frameworks natively when an operator runs on a Mac.

It's designed as the *Mac-shaped* front end for Thane: not a chat client on the side, but the canonical macOS deployment target.

## What's implemented

Working today:

- **Chat client** — Menu bar presence, Dashboard window, conversation history (SwiftData)
- **WebSocket transport** — Auth handshake and platform request routing to a Thane server
- **Binary update manager** — GitHub release polling, signed pkg install, SHA-256 verification, atomic stop/restart
- **Process Health** — Live resource stats, code-signature inspection, installer provenance

Nascent:

- **Calendar provider** — EventKit-backed, lightly exercised. Permission flow works; request coverage is minimal and untested at scale

Not started:

- Contacts, Reminders, Focus modes, Shortcuts

The platform-provider architecture (`PlatformServiceRouter`, `PlatformServiceProvider` protocol) is ready to host more providers as they land.

## Install

Download the latest signed `.dmg` from the [Releases page](https://github.com/nugget/thane-agent-macos/releases/latest) and drag the app into Applications.

Point it at your running [Thane](https://github.com/nugget/thane-ai-agent) server in Settings → Connection, and it'll handle the `thane` binary on disk for you.

## Build from source

Requires Xcode 26+ and [just](https://github.com/casey/just).

```bash
git clone https://github.com/nugget/thane-agent-macos.git
cd thane-agent-macos
just build
```

`just ci` runs the full gate (build + tests). See [CLAUDE.md](CLAUDE.md) for project conventions.

## Releases

Tagged releases publish a signed, notarized, stapled `.dmg` plus a SHA-256
checksums file to GitHub. The release workstation drives the whole pipeline
locally — signing identity and notary profile stay in the operator's
keychain.

- `just release 0.1.0` — cut a formal release (tag, DMG, notarize, staple, upload)
- `just release 0.2.0-rc.1` — auto-detected as a prerelease

See [CHANGELOG.md](CHANGELOG.md) for what's in each release.

## Architecture at a glance

- **App entry / windows** — `ThaneApp.swift`, `AppState.swift` (central `@Observable` coordinator)
- **Local server** — `BinaryManager.swift` (process lifecycle, signature inspection), `UpdateManager.swift` (release polling, download, verify, install)
- **Connection** — `ServerConnection.swift` (WebSocket client with auth handshake and platform request routing)
- **Platform services** — `PlatformServiceRouter.swift` dispatches requests to registered providers (currently: `CalendarService`)
- **Chat** — SwiftUI chat view backed by SwiftData (`Conversation`, `ChatMessage`)
- **Process Health** — Live resource stats and code-signature summary

## Related

- **[nugget/thane-ai-agent](https://github.com/nugget/thane-ai-agent)** — The Go agent this app connects to. Start there if you don't have a Thane running yet.
- **[Thane docs](https://github.com/nugget/thane-ai-agent/tree/main/docs)** — Philosophy, architecture, configuration, deployment
- **[WebSocket protocol design](https://github.com/nugget/thane-ai-agent/issues/627)** — The platform service contract this app implements

## License

Apache 2.0 — aligned with [Thane](https://github.com/nugget/thane-ai-agent) and Home Assistant.
