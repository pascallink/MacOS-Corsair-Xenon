#!/bin/bash
# XeneonEdge for macOS — one-time setup for the cloud-usage relay.
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Creates ONE secret GitHub Gist that remote/cloud Claude Code sessions will
# publish their usage into (via .claude/hooks/publish-claude-usage.sh), and
# that your Mac's XeneonEdge dashboard/widget reads back. Run this ONCE,
# locally, wherever you have `gh` authenticated.
#
# A "secret" gist is unlisted, not access-controlled: anyone who learns the
# ID can read it. That's an acceptable tradeoff here ONLY because the hook
# never puts anything but {timestamp, model, token counts} in it — never
# prompt or response text. See docs/CLAUDE-USAGE-WIDGET.md before using this.
set -euo pipefail

if ! command -v gh >/dev/null 2>&1; then
  echo "Dieses Skript braucht die GitHub-CLI (gh). Ohne gh: siehe die manuelle" >&2
  echo "curl-Variante in docs/CLAUDE-USAGE-WIDGET.md." >&2
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "Nicht bei GitHub angemeldet. Zuerst: gh auth login" >&2
  exit 1
fi

TMP_FILE="$(mktemp /tmp/xeneon-usage-relay.XXXXXX.jsonl)"
trap 'rm -f "$TMP_FILE"' EXIT
echo '{"note":"XeneonEdge Claude usage relay — see docs/CLAUDE-USAGE-WIDGET.md"}' > "$TMP_FILE"

echo "==> creating secret gist"
GIST_URL="$(gh gist create --secret --desc "XeneonEdge Claude usage relay" "$TMP_FILE")"
GIST_ID="$(basename "$GIST_URL")"

echo
echo "==> Gist angelegt: ${GIST_URL}"
echo
echo "1) Auf dem Mac (liest, kein Token nötig) — in"
echo "   ~/Library/Application Support/XeneonEdge/config.json UND/ODER"
echo "   ~/Library/Application Support/XeneonEdge/claude-widget.json setzen:"
echo "     \"cloudGistID\": \"${GIST_ID}\""
echo
echo "2) In JEDER Remote-/Cloud-Umgebung, die getrackt werden soll, als"
echo "   Umgebungsvariablen setzen (schreibt, braucht ein Token):"
echo "     XENEON_USAGE_GIST_ID=${GIST_ID}"
echo "     XENEON_USAGE_GIST_TOKEN=<classic GitHub PAT mit Scope 'gist'>"
echo "   PAT erstellen: https://github.com/settings/tokens (classic, nur 'gist')"
echo
echo "3) Dieses Repo (oder jedes andere, dessen Remote-Sessions du tracken"
echo "   willst) braucht .claude/settings.json mit dem Stop-Hook — liegt"
echo "   hier bereits unter .claude/settings.json + .claude/hooks/."
echo
echo "Danach: Menüleiste \"Konfiguration neu laden\" wählen."
