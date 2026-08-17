# AutoAgent Status

A macOS **menu bar app** for the `auto-agent-ai` CLI — see your shared Claude Code
credential status at a glance, without ever opening a terminal.

## Features

- 🔑 **Menu bar status** — icon + live token countdown (`2h 15m`), turns to a
  warning when something is wrong
- 📋 **Status panel** — credential (role, token expiry), today's Claude Code
  token usage (same numbers as the CLI), watcher state, server health
- 🖱 **One-click actions** — Login / Logout, plus **Push credential** for the
  primary user (owner), mirroring the CLI menu
- 👥 **Session info** — which AI session this Mac pulls from and who else is on
  it, straight from `/ai-sessions/me`
- 🎨 **Figma tab** — mirrors `auto-agent-ai figma`: the shared session you're
  assigned to (name, which account it signs you in as, when it was captured),
  the Figma accounts signed in on this Mac, and a one-tap import — Figma
  Desktop is quit and reopened for you, since the CLI can't write cookies while
  it's running. Import is offered only when a login has actually been uploaded,
  exactly like the CLI. Owners also get Share / Revoke / Switch token
- 🔐 **Microsoft sign-in** — opens your browser for OAuth and shows the sign-in
  link (with Open / Copy) as a fallback if the browser doesn't pop up
- 🔔 **Notifications** — watcher stopped, credential wiped, token expired,
  sign-in required, Figma session imported, back to normal
- 🔄 **Self-healing** — if the watcher dies, the app logs in again
  automatically with your last role (toggleable)
- ⬆️ **Auto-updates** — the app updates itself from this repo's Releases
  ("Update App" button), and offers to update the CLI when a new version ships.
  The CLI check uses the server's own version gate (`/app-versions/check`), so
  you see the release notes and get warned about a mandatory update *before* a
  command hits the "update required" hard-block

## Install

**One line.** Open Terminal and run:

```bash
curl -fsSL https://raw.githubusercontent.com/haonguyenstech/autoagent-status/main/install.sh | bash
```

It downloads the latest release, removes the Gatekeeper quarantine flag, and
launches the app. Run it again any time to update.

**Manual** — download the latest `AutoAgent-Status-x.y.z.zip` from
[Releases](../../releases), unzip, then run:

```bash
bash Install.command
```

> Do **not** double-click the `.app` straight from the zip — macOS Gatekeeper
> will block it ("Apple could not verify…"). The installer (or the one-liner)
> removes the quarantine flag for you. If you already hit the warning: click
> *Done*, then System Settings → Privacy & Security → *Open Anyway*.

### Requirements

- macOS 13+ (Apple Silicon or Intel — the binary is universal)
- [Node.js](https://nodejs.org) ≥ 18 (for the CLI) — the **Figma tab** needs
  Node ≥ 22.5, which the CLI uses for its built-in SQLite cookie access
- Figma Desktop in `/Applications` (only for the Figma tab)
- The `auto-agent-ai` CLI:
  ```bash
  npm install -g @saigontechnology/auto-agent
  ```
  The CLI is a **saigontechnology org package** — you need org access and a
  GitHub token with the `read:packages` scope to install it. (The app itself
  is public; only the CLI is org-gated.)

## Updating

Nothing to do. The app checks this repo's Releases every 6 hours (or instantly
via the **↻ Refresh** button) and shows an **Update App** button when a new
version exists. Click it — the app replaces itself and restarts. Or re-run the
install one-liner above.

## Uninstall

Quit the app (power button in the panel footer), then delete
`~/Applications/AutoAgent Status.app`. To also remove the credential sync:
`auto-agent-ai logout && npm uninstall -g @saigontechnology/auto-agent`.

---

## For the maintainer

Source lives at `~/auto-agent-status` on the maintainer's machine
(Swift, single file, built with `swiftc` — no Xcode project).

**Release a new version:**

```bash
# 1. bump CFBundleShortVersionString (and CFBundleVersion) in Info.plist
# 2. make sure the right GitHub account is active:
gh auth switch --user haonguyenstech
# 3. build + publish the release:
./release.sh
```

`release.sh` builds the universal binary, packages `dist/AutoAgent-Status-<ver>.zip`,
and creates the GitHub Release. New users install via the public one-liner
(`install.sh` in this repo); existing apps self-update from Releases.

This repo is **public** and the app embeds **no secrets** — the shared Claude
Code credential lives in each user's macOS Keychain, managed by the CLI.
