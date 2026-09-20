#!/bin/bash
# XeneonEdge for macOS — runs the unit tests, with or without a full Xcode.
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The tests use swift-testing (`import Testing`) rather than XCTest, because
# XCTest ships only with Xcode while swift-testing also comes with the
# Command Line Tools — that is what keeps `swift test` runnable on a
# CLT-only machine. SwiftPM does not wire up the CLT copy on its own, so we
# pass the framework search path plus the two runtime search paths. Under a
# full Xcode none of that is needed and plain `swift test` is used, which is
# also what CI calls. A missing Testing.framework under a Command Line Tools
# path is a broken or incomplete install, not a sign of full Xcode — that
# case must abort loudly instead of falling back to plain `swift test`,
# which would otherwise fail later with a misleading "no such module
# 'Testing'" error pointing at the first test file instead of the install.
set -euo pipefail

cd "$(dirname "$0")/.."

if ! DEVELOPER_DIR_PATH="$(xcode-select -p 2>/dev/null)" || [ -z "${DEVELOPER_DIR_PATH}" ]; then
    echo "error: keine Developer-Tools gefunden (xcode-select -p ist fehlgeschlagen)." >&2
    echo "Naechster Schritt: xcode-select --install" >&2
    exit 1
fi

FRAMEWORKS="${DEVELOPER_DIR_PATH}/Library/Developer/Frameworks"
INTEROP_LIB="${DEVELOPER_DIR_PATH}/Library/Developer/usr/lib"

if [ -d "${FRAMEWORKS}/Testing.framework" ]; then
    echo "==> swift test (swift-testing from ${DEVELOPER_DIR_PATH})"
    exec swift test "$@" \
        -Xswiftc -F -Xswiftc "${FRAMEWORKS}" \
        -Xlinker -F -Xlinker "${FRAMEWORKS}" \
        -Xlinker -rpath -Xlinker "${FRAMEWORKS}" \
        -Xlinker -rpath -Xlinker "${INTEROP_LIB}"
fi

# Testing.framework is missing. Decide whether this is a broken Command Line
# Tools install (must abort, never fall back) or a full Xcode (the one
# legitimate fallback to plain `swift test`).
case "${DEVELOPER_DIR_PATH}" in
    *CommandLineTools*)
        echo "error: Testing.framework nicht gefunden unter ${FRAMEWORKS}." >&2
        echo "Das ist eine unvollstaendige oder beschaedigte Command-Line-Tools-Installation, kein volles Xcode." >&2
        echo "Abhilfe: sudo rm -rf ${DEVELOPER_DIR_PATH}" >&2
        echo "         sudo xcode-select --install" >&2
        echo "Bleibt der Installationsdialog aus, zeigt 'softwareupdate --list' die verfuegbaren CLT-Versionen." >&2
        exit 1
        ;;
    *.app/Contents/Developer)
        # Full Xcode: SwiftPM finds swift-testing by itself.
        echo "==> swift test"
        exec swift test "$@"
        ;;
    *)
        echo "error: Testing.framework nicht gefunden unter ${FRAMEWORKS}." >&2
        echo "Der Developer-Pfad ${DEVELOPER_DIR_PATH} passt weder auf Command Line Tools noch auf ein Xcode.app-Bundle." >&2
        echo "Kein Rueckfall - lieber laut scheitern als raten." >&2
        exit 1
        ;;
esac
