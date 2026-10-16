# Changelog

All notable changes to Bossa. Versions follow [Semantic Versioning](https://semver.org/);
the version lives in the `VERSION` file (the only place to edit) and the build number is the build timestamp.

## [Unreleased]

## [0.1.1] - 2026-10-16

Maintenance release: build and release automation. No app behavior changes.

- CI workflow: Rust tests and a full app build on every pull request and push to `main`.
- Tag-driven release workflow: pushing a `v*` tag builds `Bossa.app`, zips it, writes a SHA-256 checksum and publishes a GitHub release with these notes.
- `bose-cli` moved into the Cargo workspace so the protocol crates have a single copy.
- GitHub Actions `checkout` bumped to v7.

## [0.1.0]

First native release (SwiftUI + Liquid Glass on macOS 26+, Rust core over BLE/BMAP).

- Menu-bar panel with battery, Mac output volume, modes, noise control, immersive audio, equalizer and shortcut.
- "Not connected" screen: searching, not in range, Bluetooth off and needs-pairing states, with the last known battery, mode and time seen.
- English, Spanish and Portuguese, following the system language or chosen in Settings.
- Low-battery notifications, open at login, version shown in Settings.
