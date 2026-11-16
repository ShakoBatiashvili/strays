#!/bin/bash
# Installs dist/Strays.app into ~/Applications. No sudo, nothing outside your home folder.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="dist/Strays.app"
DEST="$HOME/Applications/Strays.app"

[ -d "$SRC" ] || { echo "Build first: scripts/build-app.sh"; exit 1; }

# Quit a running copy so the new build replaces it cleanly.
if pgrep -x Strays >/dev/null 2>&1; then
  echo "==> Quitting the running Strays"
  osascript -e 'tell application id "io.github.shakobatiashvili.strays" to quit' >/dev/null 2>&1 || pkill -x Strays || true
  sleep 1
fi

mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$SRC" "$DEST"
codesign --verify --strict "$DEST"
echo "Installed $DEST"
echo
echo "Open it:        open \"$DEST\""
echo "Command line:   \"$DEST/Contents/Helpers/strays\" help"
echo "Put it on PATH: ln -sf \"$DEST/Contents/Helpers/strays\" /usr/local/bin/strays   (or any folder on your PATH)"
