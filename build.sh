#!/bin/zsh
# Builds ClaudeBuddy.app (with Sparkle embedded) into ./build
set -euo pipefail
cd "${0:A:h}"
VERSION=$(cat VERSION)
SPARKLE=vendor/Sparkle
FEED_URL="https://raw.githubusercontent.com/ispykenny/claude-buddy/main/appcast.xml"
PUBLIC_ED_KEY="YNsAbGGhoJ1P0w2zKEJhnRNTwHBz1fhQOORryAM/888="

if [[ ! -d $SPARKLE/Sparkle.framework ]]; then
  mkdir -p $SPARKLE
  curl -sL https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz | tar -xJ -C $SPARKLE
fi

APP=build/ClaudeBuddy.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp -R $SPARKLE/Sparkle.framework "$APP/Contents/Frameworks/"

swiftc -O -swift-version 5 -target arm64-apple-macosx13.0 \
  -F $SPARKLE -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  Sources/main.swift -o "$APP/Contents/MacOS/ClaudeBuddy"

"$APP/Contents/MacOS/ClaudeBuddy" icon build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.kennykrosky.ClaudeBuddy</string>
  <key>CFBundleName</key><string>Claude Buddy</string>
  <key>CFBundleDisplayName</key><string>Claude Buddy</string>
  <key>CFBundleExecutable</key><string>ClaudeBuddy</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Claude Buddy reads the spinner word from your iTerm2 tab so the menu bar matches the terminal.</string>
  <key>SUFeedURL</key><string>$FEED_URL</string>
  <key>SUPublicEDKey</key><string>$PUBLIC_ED_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
</dict></plist>
PLIST

# Ad-hoc sign inside-out: Sparkle's helpers, the framework, then the app.
FW="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for item in "$FW"/XPCServices/*.xpc "$FW/Autoupdate" "$FW/Updater.app" "$APP/Contents/Frameworks/Sparkle.framework" "$APP"; do
  codesign --force --sign - "$item"
done
echo "Built $APP ($VERSION)"
