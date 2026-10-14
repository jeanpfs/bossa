#!/usr/bin/env bash
# Build "Bossa.app" (native SwiftUI + Liquid Glass, Rust core linked statically), ad-hoc signed.
#   scripts/build.sh            -> build/Bossa.app
#   scripts/build.sh --run      -> also (re)launch it   (TRAY_SHOW=1 / TRAY_PIN=1 open the panel at launch)
#   scripts/build.sh --install  -> also copy to ~/Applications and launch
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cargo build --release --manifest-path "$ROOT/core/Cargo.toml" >&2

OUT="$ROOT/build"; APP="$OUT/Bossa.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Fonts"
cp "$ROOT"/fonts/*.ttf "$APP/Contents/Resources/Fonts/"
for l in en es pt; do mkdir -p "$APP/Contents/Resources/$l.lproj"; cp "$ROOT/i18n/$l.lproj/Localizable.strings" "$APP/Contents/Resources/$l.lproj/"; done
[ -f "$ROOT/icons/icon.icns" ] && cp "$ROOT/icons/icon.icns" "$APP/Contents/Resources/icon.icns"

swiftc -O -swift-version 5 -parse-as-library \
  -target arm64-apple-macosx26.0 \
  -import-objc-header "$ROOT/core/include/bose_core.h" \
  "$ROOT"/app/*.swift \
  "$ROOT/target/release/libbose_core.a" \
  -framework AppKit -framework SwiftUI -framework CoreBluetooth -framework CoreAudio -framework CoreFoundation -framework UserNotifications -liconv \
  -o "$APP/Contents/MacOS/Bossa" >&2

VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
BUILD="$(date +%y%m%d%H%M)"
CARGO_VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' "$ROOT/core/Cargo.toml" | head -1)"
[ "$CARGO_VERSION" = "$VERSION" ] || echo "warning: core/Cargo.toml version ($CARGO_VERSION) differs from VERSION ($VERSION)" >&2
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.jeanpfs.bossa</string>
<key>CFBundleName</key><string>Bossa</string>
<key>CFBundleDisplayName</key><string>Bossa</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>es</string><string>pt</string></array>
<key>CFBundleExecutable</key><string>Bossa</string>
<key>CFBundleIconFile</key><string>icon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSBluetoothAlwaysUsageDescription</key><string>Reads the battery and noise-cancelling state of your Bose headphones.</string>
</dict></plist>
PLIST
codesign -s - -f --deep "$APP" >&2
echo "built: $APP" >&2

launch() {
  pkill -f "Bossa.app/Contents/MacOS" 2>/dev/null || true
  sleep 0.3
  : > /tmp/bossa.log
  local env=()
  [ -n "${TRAY_SHOW:-}" ] && env+=(--env TRAY_SHOW=1)
  [ -n "${TRAY_PIN:-}" ] && env+=(--env TRAY_PIN=1)
  [ -n "${TRAY_GO:-}" ] && env+=(--env "TRAY_GO=$TRAY_GO")
  [ -n "${TRAY_OFFLINE:-}" ] && env+=(--env "TRAY_OFFLINE=$TRAY_OFFLINE")
  [ -n "${TRAY_SWITCH:-}" ] && env+=(--env "TRAY_SWITCH=$TRAY_SWITCH")
  [ -n "${TRAY_SHEET:-}" ] && env+=(--env "TRAY_SHEET=$TRAY_SHEET")
  local largs=(); [ -n "${TRAY_LANG:-}" ] && largs=(--args -AppleLanguages "($TRAY_LANG)")
  open -n --stdout /tmp/bossa.log --stderr /tmp/bossa.log ${env[@]+"${env[@]}"} "$1" ${largs[@]+"${largs[@]}"}
  echo "launched; log: /tmp/bossa.log" >&2
}
case "${1:-}" in
  --run) launch "$APP" ;;
  --install)
    # Replace the pre-rename "Bose Tray" app and carry its "open at login" over to the new identifier.
    pkill -f "Bose Tray.app/Contents/MacOS" 2>/dev/null || true
    rm -rf "$HOME/Applications/Bose Tray.app"
    LEGACY="$HOME/Library/LaunchAgents/dev.local.bosetray.plist"
    if [ -f "$LEGACY" ]; then
      launchctl unload "$LEGACY" 2>/dev/null || true
      rm -f "$LEGACY"
      cat > "$HOME/Library/LaunchAgents/dev.jeanpfs.bossa.plist" <<AGENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>dev.jeanpfs.bossa</string>
<key>ProgramArguments</key><array><string>/usr/bin/open</string><string>-g</string><string>-a</string><string>$HOME/Applications/Bossa.app</string></array>
<key>RunAtLoad</key><true/>
</dict></plist>
AGENT
    fi
    mkdir -p "$HOME/Applications"; rm -rf "$HOME/Applications/Bossa.app"; cp -R "$APP" "$HOME/Applications/"; launch "$HOME/Applications/Bossa.app" ;;
esac
