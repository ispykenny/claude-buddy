#!/bin/zsh
# Builds, installs to ~/Applications, wires up Claude Code hooks, and launches.
set -euo pipefail
cd "${0:A:h}"
./build.sh

DEST="$HOME/Applications/ClaudeBuddy.app"
pkill -x ClaudeBuddy 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST" && cp -R build/ClaudeBuddy.app "$DEST"

HOOK="$DEST/Contents/MacOS/ClaudeBuddy hook"
SETTINGS="$HOME/.claude/settings.json"
[[ -f "$SETTINGS" ]] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak.claude-buddy"

EVENTS='["SessionStart","UserPromptSubmit","PreToolUse","PostToolUse","PermissionRequest","Notification","Stop","StopFailure","SessionEnd"]'
jq --arg cmd "$HOOK" --argjson events "$EVENTS" '
  reduce $events[] as $e (.;
    if ([.hooks[$e][]?.hooks[]?.command] | index($cmd)) then .
    else .hooks[$e] += [{"hooks": [{"type": "command", "command": $cmd, "timeout": 5}]}] end)
' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"

open "$DEST"
echo "Installed. Hooks added to $SETTINGS (backup at $SETTINGS.bak.claude-buddy)."
