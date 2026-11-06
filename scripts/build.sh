#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="${OPENCOMPUTER_OUTPUT:-build/opencomputer-native}"
mkdir -p "$(dirname "$DEST")"
SDK="$(xcrun --show-sdk-path)"
ARCH="${OPENCOMPUTER_ARCH:-$(uname -m)}"
xcrun swiftc -O -sdk "$SDK" -target "${ARCH}-apple-macos14.0" native/*.swift -o "$DEST" -framework AppKit -framework ApplicationServices -framework ScreenCaptureKit
codesign --force --sign - --identifier cc.opencomputer.helper "$DEST"
