#!/bin/bash
# Builds dist/Strays.app from source with the Swift toolchain you already have.
# No Xcode project, no third-party dependencies, no network access needed.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="0.1.0"
BUILD="1"
APP="dist/Strays.app"
BUNDLE_ID="io.github.shakobatiashvili.strays"

# Extra flags for `swift build`. Homebrew's build sandbox needs SWIFTPM_FLAGS=--disable-sandbox
# (SwiftPM's own sandbox cannot nest inside it); normal builds leave this empty.
SWIFTPM_FLAGS="${SWIFTPM_FLAGS:-}"

echo "==> Building (release)"
# shellcheck disable=SC2086  # SWIFTPM_FLAGS is intentionally word-split
swift build $SWIFTPM_FLAGS -c release --product StraysApp
swift build $SWIFTPM_FLAGS -c release --product strays
BIN="$(swift build $SWIFTPM_FLAGS -c release --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/StraysApp" "$APP/Contents/MacOS/Strays"
cp "$BIN/strays" "$APP/Contents/Helpers/strays"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Drop debug and local symbols: they carry absolute build paths. Stripping happens before signing.
strip -x -S "$APP/Contents/MacOS/Strays" "$APP/Contents/Helpers/strays"

# A menu-bar agent (no Dock icon), no URL scheme. The one privacy string is for "Show terminal tab",
# which asks Terminal (or iTerm2) to bring a tab to the front.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>Strays</string>
	<key>CFBundleDisplayName</key><string>Strays</string>
	<key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
	<key>CFBundleExecutable</key><string>Strays</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>${VERSION}</string>
	<key>CFBundleVersion</key><string>${BUILD}</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>LSUIElement</key><true/>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>NSAppleEventsUsageDescription</key><string>Strays asks Terminal or iTerm2 to bring the tab running a process to the front when you click "Show terminal tab".</string>
</dict>
</plist>
PLIST

# Hardened runtime blocks Apple Events unless this one entitlement is present. Nothing else is requested.
ENTITLEMENTS="$(mktemp)"
trap 'rm -f "$ENTITLEMENTS"' EXIT
cat > "$ENTITLEMENTS" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.automation.apple-events</key><true/>
</dict>
</plist>
ENT

echo "==> Signing (ad-hoc, hardened runtime)"
codesign --force --options runtime --sign - "$APP/Contents/Helpers/strays"
codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign - "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo
echo "Built $APP (version $VERSION)"
echo "Next: scripts/audit.sh, then scripts/install.sh"
