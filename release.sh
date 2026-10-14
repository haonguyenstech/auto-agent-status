#!/bin/bash
# Build + publish a new app version to GitHub Releases (public repo).
# Usage: ./release.sh
# Apps in the field see the new version on their next check (6 h) or manual Refresh.
# New users install with the one-liner in README.md (install.sh from this repo).
set -euo pipefail
cd "$(dirname "$0")"

REPO="haonguyenstech/auto-agent-status"

./package.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
ZIP="dist/Auto-Agent-Status-$VERSION.zip"

echo ""
echo "Releasing v$VERSION to github.com/$REPO …"
gh release create "v$VERSION" "$ZIP" \
  --repo "$REPO" \
  --title "v$VERSION" \
  --notes "Auto Agent Status v$VERSION — menu bar app for auto-agent-ai." \
  || { echo "Release v$VERSION may already exist. Bump the version in Info.plist first."; exit 1; }

echo "✅ Released: https://github.com/$REPO/releases/tag/v$VERSION"
echo ""
echo "Install / update one-liner (public — share freely):"
echo "   curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | bash"
