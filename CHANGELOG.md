# Changelog

All notable changes to Bossa. Versions follow [Semantic Versioning](https://semver.org/);
the version lives in the `VERSION` file (the only place to edit) and the build number is the build timestamp.

## [Unreleased]

## [0.1.2] - 2026-10-16

### Fixed

- Headphones dropping out during Meet/Teams/FaceTime calls. While a call uses the headset microphone,
  Bossa now pauses its BLE polling and never scans, reconnects or re-encrypts the link; a slow answer is no
  longer treated as a lost connection (3 consecutive misses, or the OS reporting the link down), and Bossa no
  longer tears the BLE link down itself after one.
- One CoreBluetooth central is reused for the whole process instead of a new one per scan.
- Unsolicited BMAP packets are capped instead of accumulating for the whole session.

### Docs

- README demo GIF and the scripts that record it (`scripts/demo/`).

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
