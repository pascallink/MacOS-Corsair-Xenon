#!/bin/bash
# XeneonEdge for macOS — builds XeneonEdge.app from the Swift package.
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIGURATION="${1:-release}"
APP_NAME="XeneonEdge"
BUILD_DIR=".build/${CONFIGURATION}"
OUT_DIR="dist"
APP="${OUT_DIR}/${APP_NAME}.app"

echo "==> swift build -c ${CONFIGURATION}"
swift build -c "${CONFIGURATION}"

echo "==> assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

cp "${BUILD_DIR}/XeneonEdgeApp" "${APP}/Contents/MacOS/XeneonEdgeApp"
cp "${BUILD_DIR}/xeneonctl" "${OUT_DIR}/xeneonctl"
cp Resources/Info.plist "${APP}/Contents/Info.plist"

# Ad-hoc signature so TCC (Accessibility/Input Monitoring) remembers the app.
codesign --force --deep --sign - "${APP}"

echo "==> done:"
echo "    ${APP}"
echo "    ${OUT_DIR}/xeneonctl"
echo
echo "Beim ersten Start fragt macOS nach Berechtigungen:"
echo "  • Bedienungshilfen (Klick-Injektion für Touch)"
echo "  • Eingabemonitoring (HID-Touchdaten lesen)"
echo "  • Automation (Musik/Spotify für das Medien-Widget, optional)"
