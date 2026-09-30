#!/bin/zsh
# Publishes a new version via Sparkle.
# Usage: ./release.sh 1.1.0 "What changed"
set -euo pipefail
cd "${0:A:h}"
VERSION=${1:?usage: ./release.sh <version> [notes]}
NOTES=${2:-"Claude Buddy $VERSION"}
REPO=ispykenny/claude-buddy

[[ -z $(git status --porcelain) ]] || { echo "Commit or stash your changes first."; exit 1; }
git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null && { echo "v$VERSION already exists."; exit 1; }

echo "$VERSION" > VERSION
./build.sh

ZIP="build/ClaudeBuddy-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent build/ClaudeBuddy.app "$ZIP"
# Signs with the EdDSA private key in your login keychain; prints: sparkle:edSignature="…" length="…"
SIGNATURE=$(vendor/Sparkle/bin/sign_update --account claude-buddy "$ZIP")

python3 - "$VERSION" "$NOTES" "$SIGNATURE" "https://github.com/$REPO/releases/download/v$VERSION/ClaudeBuddy-$VERSION.zip" <<'PY'
import sys, html
from email.utils import formatdate
version, notes, signature, url = sys.argv[1:]
open("appcast.xml", "w").write(f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Claude Buddy</title>
    <item>
      <title>Version {version}</title>
      <pubDate>{formatdate(localtime=True)}</pubDate>
      <sparkle:version>{version}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <description><![CDATA[<p>{html.escape(notes)}</p>]]></description>
      <enclosure url="{url}" type="application/octet-stream" {signature} />
    </item>
  </channel>
</rss>
""")
PY

git add VERSION appcast.xml
git commit -m "Release $VERSION"
git tag "v$VERSION"
git push origin HEAD --tags
gh release create "v$VERSION" "$ZIP" --repo "$REPO" --verify-tag --title "Claude Buddy $VERSION" --notes "$NOTES"
echo "Released $VERSION — installed copies will pick it up on their next check."
