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
# also what CI calls.
set -euo pipefail

cd "$(dirname "$0")/.."

DEVELOPER_DIR_PATH="$(xcode-select -p)"
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

# Full Xcode: SwiftPM finds swift-testing by itself.
echo "==> swift test"
exec swift test "$@"
