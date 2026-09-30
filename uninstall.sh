#!/bin/zsh
# Removes the app and its hooks from ~/.claude/settings.json
set -euo pipefail
pkill -x ClaudeBuddy 2>/dev/null || true
SETTINGS="$HOME/.claude/settings.json"
jq 'if .hooks then .hooks |= (map_values(map(.hooks |= map(select(.command | contains("ClaudeBuddy") | not))) | map(select(.hooks | length > 0))) | with_entries(select(.value | length > 0))) else . end' \
  "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
rm -rf "$HOME/Applications/ClaudeBuddy.app" "$HOME/.claude-buddy"
echo "Uninstalled."
