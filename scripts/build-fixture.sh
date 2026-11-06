#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="build/OpenComputer Fixture.app/Contents"
mkdir -p "$DEST/MacOS"
xcrun swiftc tests/fixture.swift -o "$DEST/MacOS/fixture" -framework AppKit
cat > "$DEST/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>cc.opencomputer.fixture</string><key>CFBundleExecutable</key><string>fixture</string><key>CFBundleName</key><string>OpenComputer Fixture</string><key>CFBundleVersion</key><string>1</string><key>NSHighResolutionCapable</key><true/></dict></plist>
PLIST
codesign --force --sign - "build/OpenComputer Fixture.app"
