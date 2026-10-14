#!/usr/bin/env bash
# Run the `bose` CLI as its own macOS app bundle so Bluetooth permission (TCC) is attributed to it,
# not to the terminal that launched it (a terminal without NSBluetoothAlwaysUsageDescription makes
# macOS abort the process). First run shows a system "Allow Bluetooth" dialog.
#   scripts/bose-cli-mac.sh scan --secs 8
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="${PROFILE:-debug}"
cargo build --manifest-path "$ROOT/Cargo.toml" ${PROFILE:+$([ "$PROFILE" = release ] && echo --release)} >&2
APP="$ROOT/target/$PROFILE/Bose CLI.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$ROOT/target/$PROFILE/bose" "$APP/Contents/MacOS/bose"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.local.bose-cli</string>
<key>CFBundleName</key><string>Bose CLI</string>
<key>CFBundleExecutable</key><string>bose</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>0.1.0</string>
<key>LSUIElement</key><true/>
<key>NSBluetoothAlwaysUsageDescription</key><string>Reads the battery, volume and noise-cancelling state of your Bose headphones.</string>
</dict></plist>
PLIST
codesign -s - -f --deep "$APP" >&2
OUT="$(mktemp -t bose-out)"
open -n -W --stdout "$OUT" --stderr "$OUT" "$APP" --args "$@" || true
cat "$OUT"; rm -f "$OUT"
