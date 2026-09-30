#!/bin/zsh
# Builds, installs to ~/Applications, and launches (the app connects its Claude Code hooks itself).
set -euo pipefail
cd "${0:A:h}"
./build.sh

DEST="$HOME/Applications/ClaudeBuddy.app"
pkill -x ClaudeBuddy 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST" && cp -R build/ClaudeBuddy.app "$DEST"

open "$DEST"
echo "Installed to $DEST."
