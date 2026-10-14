#!/bin/bash
# Auto Agent Status — public installer. Always installs the latest release.
#
#   curl -fsSL https://raw.githubusercontent.com/haonguyenstech/auto-agent-status/main/install.sh | bash
#
# Public repo, no token required. Run it again any time to update.
set -e

REPO="haonguyenstech/auto-agent-status"
API="https://api.github.com/repos/$REPO/releases/latest"
APP="Auto Agent Status.app"
DEST="$HOME/Applications"

echo "==> Looking up the latest version…"
JSON=$(/usr/bin/curl -fsSL -H "Accept: application/vnd.github+json" "$API")
TAG=$(printf '%s' "$JSON" | /usr/bin/sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
ZIPURL=$(printf '%s' "$JSON" \
  | /usr/bin/grep -o '"browser_download_url": *"[^"]*\.zip"' | head -1 \
  | /usr/bin/sed 's/.*"\(https[^"]*\)"/\1/')
[ -n "$ZIPURL" ] || { echo "❌ No release asset found at $API"; exit 1; }
echo "==> Latest version: ${TAG:-unknown}"

TMP=$(mktemp -d)
echo "==> Downloading…"
/usr/bin/curl -fsSL -o "$TMP/app.zip" "$ZIPURL"
/usr/bin/ditto -x -k "$TMP/app.zip" "$TMP/x"
SRC=$(/usr/bin/find "$TMP/x" -maxdepth 2 -name "$APP" | head -1)
[ -n "$SRC" ] || SRC=$(/usr/bin/find "$TMP/x" -maxdepth 4 -name "AutoAgent Status.app" | head -1) # releases before 1.18
[ -n "$SRC" ] || { echo "❌ '$APP' not found inside the download"; exit 1; }

echo "==> Installing to $DEST …"
mkdir -p "$DEST"
pkill -x AutoAgentStatus 2>/dev/null || true
rm -rf "$DEST/$APP" "$DEST/AutoAgent Status.app" # + the pre-1.18 name
/usr/bin/ditto "$SRC" "$DEST/$APP"
# Strip the Gatekeeper quarantine flag so the app opens without warnings.
/usr/bin/xattr -dr com.apple.quarantine "$DEST/$APP" 2>/dev/null || true
rm -rf "$TMP"

# ---- The app is a GUI for the auto-agent-ai CLI (still an org package) ----
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
if ! command -v auto-agent-ai >/dev/null 2>&1; then
  echo ""
  echo "ℹ️  The auto-agent-ai CLI isn't installed yet. To set it up:"
  command -v npm >/dev/null 2>&1 || echo "    • Install Node.js ≥ 18 first (https://nodejs.org or: brew install node)"
  echo "    • npm install -g @saigontechnology/auto-agent"
  echo "      (the CLI is a saigontechnology org package — you need org access)"
fi

open "$DEST/$APP"
echo ""
echo "✅ Done! Look for the key icon in your menu bar → Client Login."
