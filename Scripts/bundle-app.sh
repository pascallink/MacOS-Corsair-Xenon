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

WIDGET_APP="${OUT_DIR}/ClaudeUsageWidget.app"
echo "==> assembling ${WIDGET_APP}"
rm -rf "${WIDGET_APP}"
mkdir -p "${WIDGET_APP}/Contents/MacOS" "${WIDGET_APP}/Contents/Resources"
cp "${BUILD_DIR}/ClaudeUsageWidget" "${WIDGET_APP}/Contents/MacOS/ClaudeUsageWidget"
cp Resources/ClaudeWidget-Info.plist "${WIDGET_APP}/Contents/Info.plist"
codesign --force --deep --sign - "${WIDGET_APP}"

echo "==> done:"
echo "    ${APP}"
echo "    ${WIDGET_APP}"
echo "    ${OUT_DIR}/xeneonctl"
echo
echo "Beim ersten Start fragt macOS nach Berechtigungen:"
echo "  • Bedienungshilfen (Klick-Injektion für Touch)"
echo "  • Eingabemonitoring (HID-Touchdaten lesen)"
echo "  • Automation (Musik/Spotify für das Medien-Widget, optional)"
