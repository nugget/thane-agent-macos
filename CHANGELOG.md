# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-04-23

First formal release. Establishes the macOS companion app as a first-class
deployment target for [thane-ai-agent](https://github.com/nugget/thane-ai-agent).

### Added

- WebSocket client and platform service provider for `thane-ai-agent`
- Binary update manager: checks GitHub releases, verifies SHA-256 checksums,
  inspects pkg signatures, installs notarized updates, and auto-restarts the
  local `thane` process
- Process Health window with live resource stats and code-signature inspection
- Menu bar presence showing connection status at a glance
- Dashboard window with conversation history (backed by SwiftData)
- About window with build provenance (git commit, branch, builder, timestamp)
- Developer ID signing, hardened runtime, and notarization for Gatekeeper trust
- Signed and notarized DMG distribution via GitHub releases

[Unreleased]: https://github.com/nugget/thane-agent-macos/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/nugget/thane-agent-macos/releases/tag/v0.1.0
