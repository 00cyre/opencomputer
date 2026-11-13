#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
xcrun swiftc -sdk "$(xcrun --show-sdk-path)" -target "$(uname -m)-apple-macos14.0" native/NativeSupport.swift native/GhostMotion.swift native/ApprovalPolicy.swift native/ActivityViews.swift native/ActivityOverlay.swift tests/overlay-ui.swift -o build/overlay-ui-test -framework AppKit -framework ApplicationServices -framework ScreenCaptureKit
# --compile-only checks that the harness and overlay compile; the Overlay screenshots workflow runs it live.
[ "${1:-}" = "--compile-only" ] && exit 0
build/overlay-ui-test "${OPENCOMPUTER_UI_OUTPUT:-work/overlay-ui}"
