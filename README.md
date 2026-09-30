# Claude Buddy

A tiny macOS menu bar critter that scuttles around while your Claude Code agents work, showing the same
spinner word as your terminal ("Flibbertigibbeting…"), one critter per busy agent.

- `./install.sh` — build, install to `~/Applications`, add the Claude Code hooks, launch
- `./release.sh 1.1.0 "notes"` — publish an update (GitHub Release + `appcast.xml`); installed copies update via Sparkle
- `./uninstall.sh` — remove the app and its hooks

Releasing needs the Sparkle EdDSA private key in your login keychain (`vendor/Sparkle/bin/generate_keys --account claude-buddy`).
