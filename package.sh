#!/bin/bash
# Build a shareable zip: dist/Auto-Agent-Status-<version>.zip
# Contains the app + double-clickable installer + README for teammates.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
APP="$HOME/Applications/Auto Agent Status.app"
STAGE="dist/Auto Agent Status $VERSION"
ZIP="dist/Auto-Agent-Status-$VERSION.zip"

rm -rf dist
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
# Apps up to v1.17.0 update themselves by looking for "AutoAgent Status.app" in
# the zip, so ship a copy under that name too, hidden. The new build moves itself
# to the new name on first launch.
mkdir -p "$STAGE/.legacy"
cp -R "$APP" "$STAGE/.legacy/AutoAgent Status.app"

cat > "$STAGE/Install.command" <<'EOF'
#!/bin/bash
# Auto Agent Status installer — run with:  bash Install.command
set -e
cd "$(dirname "$0")"
APP="Auto Agent Status.app"
DEST="$HOME/Applications"
PKG="@saigontechnology/auto-agent"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

echo "==> Installing $APP to $DEST …"
mkdir -p "$DEST"
pkill -x AutoAgentStatus 2>/dev/null || true
rm -rf "$DEST/$APP" "$DEST/AutoAgent Status.app" # + the pre-1.18 name
cp -R "$APP" "$DEST/"
# Remove the quarantine flag Gatekeeper puts on downloaded apps
xattr -dr com.apple.quarantine "$DEST/$APP" 2>/dev/null || true

# ---- CLI setup (the app is a GUI for the auto-agent-ai CLI) ----
if command -v auto-agent-ai >/dev/null 2>&1; then
  echo "==> auto-agent-ai CLI found: $(auto-agent-ai --version 2>/dev/null | tail -1)"
else
  echo ""
  echo "==> The auto-agent-ai CLI is not installed yet — setting it up."

  # 1. Node.js
  if ! command -v npm >/dev/null 2>&1; then
    echo ""
    echo "❌ Node.js is not installed. Install it first:"
    echo "     brew install node        (if you have Homebrew)"
    echo "   or download from https://nodejs.org (LTS version)"
    echo "   Then run this installer again."
    open "$DEST/$APP"
    exit 1
  fi

  # 2. GitHub token for the private registry
  if ! grep -q "npm.pkg.github.com/:_authToken" "$HOME/.npmrc" 2>/dev/null; then
    echo ""
    echo "   The CLI is a PRIVATE package — you need a GitHub token."
    echo "   1. Open https://github.com/settings/tokens"
    echo "   2. Generate new token (classic) with scope: read:packages"
    echo "      (your GitHub account must be in the saigontechnology org)"
    echo ""
    read -r -p "   Paste your GitHub token here (or press Enter to skip): " TOKEN
    if [ -n "$TOKEN" ]; then
      {
        echo "@saigontechnology:registry=https://npm.pkg.github.com"
        echo "//npm.pkg.github.com/:_authToken=$TOKEN"
      } >> "$HOME/.npmrc"
      echo "   Saved to ~/.npmrc"
    else
      echo "   Skipped. Install the CLI later with: npm install -g $PKG"
      open "$DEST/$APP"
      exit 0
    fi
  fi

  # 3. Install the CLI
  echo "==> Installing $PKG (this may take a minute)…"
  if npm install -g "$PKG"; then
    echo "==> CLI installed: $(auto-agent-ai --version 2>/dev/null | tail -1)"
  else
    echo "❌ CLI install failed. Common causes:"
    echo "   - Token missing the read:packages scope"
    echo "   - Your GitHub account has no access to saigontechnology packages (ask an org admin)"
    echo "   Fix it and run:  npm install -g $PKG"
  fi
fi

open "$DEST/$APP"
echo ""
echo "✅ Done! Look for the key icon in your menu bar (top-right)."
echo "   Click it -> Login as Owner or Client."
EOF
chmod +x "$STAGE/Install.command"

cat > "$STAGE/README.txt" <<'EOF'
Auto Agent Status — menu bar app for the auto-agent-ai CLI
===========================================================

WHAT IT DOES
  Lives in your macOS menu bar and shows the status of your shared
  Claude Code credential: token countdown, watcher state, server health.
  One-click Login (owner/client), Push, Logout — no terminal needed.
  Extras: notifications when something breaks, auto-restart of the
  watcher if it dies, CLI update check.

REQUIREMENTS
  - macOS 13 or newer (Apple Silicon or Intel)
  - Node.js >= 18 (brew install node, or https://nodejs.org)
  - A GitHub account with access to the saigontechnology org packages,
    and a Personal Access Token (classic) with the read:packages scope
    from https://github.com/settings/tokens
  The installer below sets up everything else (npm config + the
  auto-agent-ai CLI) automatically — it will ask for your token.

INSTALL  (IMPORTANT: run the installer — do NOT open the .app directly!)
  1. Open Terminal (Cmd+Space, type "Terminal").
  2. Type "bash " (with a space), then drag "Install.command" from
     Finder into the Terminal window, and press Enter.
     The installer copies the app, removes Apple's quarantine flag,
     and launches it — no security warnings.
  3. Allow notifications when the app asks (recommended).
  4. Click the key icon in the menu bar -> Login as Owner or Client.
  5. Optional: turn on "Start at Login" in the panel footer.

IF YOU SEE "Apple could not verify … free of malware"
  You opened the app directly without the installer. Click "Done"
  (NOT "Move to Trash"), then either:
    a) System Settings -> Privacy & Security -> scroll down ->
       "Open Anyway" -> Open, or
    b) run the installer as described in INSTALL above.

UNINSTALL
  Quit the app from its panel (power button), then delete
  ~/Applications/Auto Agent Status.app
EOF

ditto -c -k --sequesterRsrc --keepParent "$STAGE" "$ZIP"
echo ""
echo "Package ready: $(pwd)/$ZIP"
du -h "$ZIP" | cut -f1
