#!/bin/bash
# XeneonEdge for macOS — installs the app to /Applications and enables
# autostart via a per-user LaunchAgent.
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

cd "$(dirname "$0")/.."

APP="dist/XeneonEdge.app"
PLIST_SRC="LaunchAgents/de.pascallink.xeneonedge.plist"
PLIST_DST="${HOME}/Library/LaunchAgents/de.pascallink.xeneonedge.plist"

if [[ ! -d "${APP}" ]]; then
  echo "dist/XeneonEdge.app fehlt — zuerst Scripts/bundle-app.sh ausführen." >&2
  exit 1
fi

echo "==> installing to /Applications"
rm -rf "/Applications/XeneonEdge.app"
cp -R "${APP}" /Applications/

echo "==> installing xeneonctl to /usr/local/bin (sudo)"
sudo install -m 0755 dist/xeneonctl /usr/local/bin/xeneonctl

echo "==> enabling autostart (LaunchAgent)"
mkdir -p "${HOME}/Library/LaunchAgents"
cp "${PLIST_SRC}" "${PLIST_DST}"
launchctl unload "${PLIST_DST}" 2>/dev/null || true
launchctl load "${PLIST_DST}"

echo "==> fertig. XeneonEdge läuft als Menüleisten-App."
