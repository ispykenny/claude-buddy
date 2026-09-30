#!/bin/bash
# Removes Claude Buddy and its Claude Code hooks:
#   curl -fsSL https://raw.githubusercontent.com/ispykenny/claude-buddy/main/uninstall.sh | bash
set -euo pipefail

pkill -x ClaudeBuddy 2>/dev/null || true
for app in "$HOME/Applications/ClaudeBuddy.app" "/Applications/ClaudeBuddy.app"; do
  if [[ -x "$app/Contents/MacOS/ClaudeBuddy" ]]; then
    "$app/Contents/MacOS/ClaudeBuddy" hooks uninstall >/dev/null
  fi
  rm -rf "$app"
done
rm -rf "$HOME/.claude-buddy"
defaults delete dev.kennykrosky.ClaudeBuddy 2>/dev/null || true
echo "Claude Buddy uninstalled."
