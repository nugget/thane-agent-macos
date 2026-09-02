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

- **Native containment.** This is the big one. The app brings Thane into macOS's native privacy and security model so operators can contain the agent using the same guarantees Apple offers every other app on the system:
  - **TCC-gated data access.** Platform-provider calls into Calendar (and Contacts, Reminders, Focus, Shortcuts as they land) go through macOS's Transparency, Consent, and Control framework. The user grants consent per capability and can revoke it from System Settings — not a global trust-the-agent toggle.
  - **Declared entitlements.** The app declares exactly what it can touch in its entitlements file. Anything not listed, it can't reach. Add a capability, add an entitlement, prompt the user — the OS enforces the envelope.
  - **Hardened runtime + Developer ID + notarization.** Library validation, no dyld injection, no writable-and-executable memory. Signed by a real Apple Developer ID, notarized by Apple so Gatekeeper trusts every DMG. Operators see the provenance before they launch.
  - **Supervised local binary.** When run as a local Thane host, the app inspects the `thane` binary's code signature and notarization status via Security.framework before launch and surfaces that provenance in Process Health. The operator knows which process they're running, not just that *some* `thane` is on disk.
- **Install and updates.** The app downloads signed `.pkg` releases from GitHub, verifies SHA-256 checksums and notarization, installs atomically, and supervises the local process.
- **Operator UI.** Menu bar, chat window, Process Health view with resource stats and code-signature inspection — no terminal required for day-to-day use.
- **Core identity evidence.** The Identity window surfaces Thane's stable instance ID, founding public-key fingerprints, signed birth and active core revisions, anchor posture, and separate admission/HEAD verification results without presenting them as a self-issued trust verdict. The companion saves the first founding identity it sees for each server and warns like a changed safety number if that identity later differs.
- **Apple-ecosystem integration.** Calendar, Contacts, Focus, Reminders, and Shortcuts live behind Apple frameworks that aren't reachable from a Linux agent without lossy workarounds (CardDAV scraping, ICS polling). This app is the bridge that lets Thane reach into those frameworks natively when an operator runs on a Mac.

It's designed as the *Mac-shaped* front end for Thane: not a chat client on the side, but the canonical macOS deployment target — with the full macOS security stack between the operator and the agent.

## What's implemented

Working today:

- **Native operator app** — A dedicated chat window, searchable conversation history, keyboard commands, configurable menu bar status, and a first-class web Dashboard window
- **WebSocket transport** — Auth handshake and platform request routing to a Thane server
- **Binary update manager** — GitHub release polling, signed pkg install, SHA-256 verification, atomic stop/restart
- **Signed-core supervision** — Preflight validation of `core/config.yaml`, terminal exit handling, repair guidance, live resource stats, code-signature inspection, and installer provenance

Nascent:

- **Calendar provider** — EventKit-backed and default-off. A dedicated Calendar settings tab separates macOS permission from an app-owned export gate and per-calendar allowlist. The operator can add a description for each shared calendar; `macos_calendars_list` gives Thane that context alongside the calendar's local identifier, source/account, type, color, supported availability, default status, and read/write characteristics. Event queries are confined to selected calendars and carry the calendar identifier with every result. Events cross the wire in the zone they are scheduled in: timed events carry their own UTC offset plus an IANA `time_zone` when the event declares one, and all-day events carry inclusive `yyyy-MM-dd` dates resolved here against the event's own calendar. Results are bounded (20 by default, 100 maximum), report truncation, and refresh after `EKEventStoreChanged`. Still narrow and untested at scale: no update or delete, attendee or recurrence metadata, or separately configurable write policy.
- **Contacts provider** — Contacts-framework-backed search (name, org, email, phone) with a bounded result size, exposed to the agent as `macos_contacts_search`. Permission flow works; read-only, with no per-field export policy (tracked upstream in [thane-ai-agent#1017](https://github.com/nugget/thane-ai-agent/issues/1017))

Not started:

- Reminders, Focus modes, Shortcuts

The platform-provider architecture (`PlatformServiceRouter`, `PlatformServiceProvider` protocol) is ready to host more providers as they land.

## Install

Download the latest signed `.dmg` from the [Releases page](https://github.com/nugget/thane-agent-macos/releases/latest) and drag the app into Applications.

After first launch, open **Settings → Thane** and choose a configuration. Once configured, chat, the menu bar, Dashboard, and platform services use neutral Thane status — the process location stays an implementation detail.

### Managed

Managed is the default. The app installs, verifies, updates, and supervises Thane on this Mac:

1. Open **Settings → Thane → Managed**
2. The app auto-discovers `thane` in `~/Thane/bin/`, `/usr/local/bin/`, `/opt/homebrew/bin/`, and `~/.local/bin/`. If none is present, the **Binary Updates** section downloads a signed `.pkg` directly from the [thane-ai-agent releases](https://github.com/nugget/thane-ai-agent/releases) — SHA-256 checksum + pkg signature both verified before install
3. Point **Workspace** at your Thane directory (defaults to `~/Thane/`). A current Thane instance keeps its signed runtime config at `core/config.yaml`; `thane init ~/Thane` creates that core, or the app can initialize it when startup finds a missing workspace
4. Click **Check & Start**. The app runs the same structured preflight as `thane validate`, then starts only when the config and signed core pass

When Managed is relevant, **Agent Health** shows live resource stats, signed-core status, code-signature provenance, recent activity, and restart controls. Optional Apple notifications can surface warnings quietly or errors actively, with separate controls for privacy, sound, repetition, retention, foreground delivery, and temporary muting. Repeated incidents replace themselves, bursts are summarized, and selecting a notification opens Agent Health. A terminal configuration failure (exit 78) pauses automatic restart and presents Thane's exact findings and repair commands instead of creating a crash loop. Restart requests preserve the operator's run intent and wait for actual child termination: a clean exit launches the replacement immediately, while an abnormal exit retains the crash-backoff policy. **Binary Updates** validates the active workspace with each staged binary before atomically stopping, installing, and restarting Thane; if the old process has not stopped within 60 seconds, the install aborts without replacing the live executable and surfaces the failure.

### Advanced

Advanced connects the app to a Thane instance you operate yourself on another Mac, a home server, or a NAS:

1. Open **Settings → Thane → Advanced**
2. Enter the base URL (for example, `https://thane.yourdomain.tld` or `http://thane-host.local:8080`) and API token
3. Click **Connect**

The app uses the same chat, status language, Dashboard, and macOS platform-service bridge in either configuration. Disconnect is deliberately kept in Advanced Settings rather than the menu bar because it is an exceptional, disruptive action.

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

- `just release-github 0.1.0` — cut a formal release (tag, DMG, notarize, staple, upload)
- `just release-github 0.2.0-rc.1` — auto-detected as a prerelease
- `just prepare-release 0.1.0` then `just publish-release 0.1.0` — same flow with a reviewable breakpoint between building artifacts and publishing

Release notes and artifacts live at [Releases](https://github.com/nugget/thane-agent-macos/releases).

## Architecture at a glance

- **App entry / windows** — `ThaneApp.swift`, `AppState.swift` (central `@Observable` coordinator)
- **Local server** — `BinaryManager.swift` (process lifecycle, signature inspection), `UpdateManager.swift` (release polling, download, verify, install)
- **Connection** — `ServerConnection.swift` (WebSocket client with auth handshake and platform request routing)
- **Platform services** — `PlatformServiceRouter.swift` dispatches requests to registered providers (currently: `CalendarService`, `ContactsService`)
- **Chat** — SwiftUI chat view backed by SwiftData (`Conversation`, `ChatMessage`)
- **Managed Thane** — Signed-core preflight, terminal-failure guidance, live resource stats, bounded recent activity, nuanced warning/error notifications, and code-signature summary

## Related

- **[nugget/thane-ai-agent](https://github.com/nugget/thane-ai-agent)** — The Go agent this app connects to. Start there if you don't have a Thane running yet.
- **[Thane docs](https://github.com/nugget/thane-ai-agent/tree/main/docs)** — Philosophy, architecture, configuration, deployment
- **[Realtime WebSocket contract](https://github.com/nugget/thane-ai-agent/issues/1081)** — The platform service contract this app implements (`/v1/realtime/ws`), superseding the original [#627](https://github.com/nugget/thane-ai-agent/issues/627) design

## License

Apache 2.0 — aligned with [Thane](https://github.com/nugget/thane-ai-agent) and Home Assistant.

## Privileged ports for Thane's HTTPS front door

macOS refuses ports below 1024 to ordinary users, admin or not, and offers
no capability to grant, so Thane cannot bind 443 or 80 itself. The
companion bundles a small LaunchDaemon, `thane-portbroker`, and registers
it through `SMAppService` from Settings → General → Privileged Ports. Its
plist declares `Sockets` for 443 and 80, so launchd binds them as root at
boot, whether or not the app is running, and hands the listening
descriptors to the daemon. The daemon's only job is to pass them over XPC
to this app, after checking the app's code signature, and the app starts
Thane with them at descriptors 3 and 4 under the systemd socket-activation
contract (`LISTEN_FDS`, `LISTEN_FDNAMES=https:http`) that Thane's front
door reads. Thane never runs with privilege; a Thane restart drops no
connections, because launchd still owns the socket. If the daemon is not
registered, not yet approved, or unreachable, Thane starts on its
configured ports and Process Health says why.

