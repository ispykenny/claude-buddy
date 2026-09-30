# Claude Buddy

A tiny macOS menu bar critter that scuttles around while your Claude Code agents work. It shows the same
spinner word as your terminal ("Flibbertigibbeting…"), one critter per busy agent, and jumps for joy when they finish.

*An unofficial fan project, not affiliated with Anthropic.*

## Install

1. **[Download ClaudeBuddy.zip](https://github.com/ispykenny/claude-buddy/releases/latest/download/ClaudeBuddy.zip)** and unzip it.
2. Drag **ClaudeBuddy.app** into your **Applications** folder.
3. Open it. macOS will say it can't verify the developer (the app isn't notarized), so go to
   **System Settings → Privacy & Security**, scroll down, and click **Open Anyway**.
4. Click **Connect** when it asks to connect to Claude Code. Restart any Claude Code sessions that were already open.

It updates itself from then on (menu → **Check for Updates…**).

Requires macOS 13+ and [Claude Code](https://claude.com/claude-code).

## What it does

- **Working:** a critter per busy agent walks back and forth, doing little hops and dashes, with the spinner word shimmering next to it.
  With several agents, the word rotates between them and the one "talking" waves.
- **Needs you:** frantic waving and a blinking `!` when Claude is waiting on a permission prompt.
- **Done:** a jump for joy with sparkles.
- **Idle:** blinks, waves, hops, dances, sends hearts… and naps with Zs when no sessions are open.
- **Click the critter** for a list of every running session; click one to jump to its iTerm2/Terminal tab.

The exact spinner word is read from iTerm2 (macOS asks once for permission). Other terminals get a random word from Claude Code's list.

## How it works

The app adds hooks to `~/.claude/settings.json` that run `ClaudeBuddy hook`, which writes each session's state to
`~/.claude-buddy/sessions/`. It also reads Claude Code's own session registry (`~/.claude/sessions/`) so sessions
started before the hooks still show up. Disconnect anytime from the menu (**Connected to Claude Code**).

## Development

- `./install.sh`: build, install to `~/Applications`, launch
- `./release.sh 1.3.0 "notes"`: publish an update (GitHub Release + `appcast.xml`); installed copies update via Sparkle.
  Needs the Sparkle EdDSA private key in your login keychain (`vendor/Sparkle/bin/generate_keys --account claude-buddy`).
- `./uninstall.sh`: remove the app and its hooks
- `build/ClaudeBuddy.app/Contents/MacOS/ClaudeBuddy preview sheet.png`: render every animation to one image
- `build/ClaudeBuddy.app/Contents/MacOS/ClaudeBuddy hooks install|uninstall|status`: manage the hooks from the command line
