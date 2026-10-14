#!/bin/bash
# Securely store the update token (hidden input) and release.
# The token is NEVER printed and never leaves your machine.
set -euo pipefail
cd "$(dirname "$0")"

echo "Paste the GitHub token, then press Enter (it stays hidden):"
read -rs TOKEN
echo ""
if [ -z "$TOKEN" ]; then echo "No token entered. Aborting."; exit 1; fi

printf '%s' "$TOKEN" > .update-token
chmod 600 .update-token
unset TOKEN

CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $(cat .update-token)" \
  https://api.github.com/repos/haonguyenstech/auto-agent-status/releases/latest)
if [ "$CODE" != "200" ]; then
  echo "❌ Token check failed (HTTP $CODE). Token may be wrong or already revoked."
  exit 1
fi
echo "✅ Token valid. Releasing…"
./release.sh
