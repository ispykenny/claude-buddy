#!/bin/bash
# Installs (or updates) Claude Buddy:
#   curl -fsSL https://raw.githubusercontent.com/ispykenny/claude-buddy/main/install.sh | bash
set -euo pipefail

URL="https://github.com/ispykenny/claude-buddy/releases/latest/download/ClaudeBuddy.zip"
DEST="$HOME/Applications/ClaudeBuddy.app"

major=$(sw_vers -productVersion | cut -d. -f1)
if (( major < 13 )); then
  echo "Claude Buddy needs macOS 13 or newer." >&2
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "Downloading Claude Buddy…"
curl -fsSL "$URL" -o "$tmp/ClaudeBuddy.zip"
ditto -x -k "$tmp/ClaudeBuddy.zip" "$tmp"

pkill -x ClaudeBuddy 2>/dev/null || true
mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST"
mv "$tmp/ClaudeBuddy.app" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

open "$DEST"
echo "Installed to $DEST — look for the little critter in your menu bar and click Connect."
