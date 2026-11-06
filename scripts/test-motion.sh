#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcrun swiftc native/GhostMotion.swift tests/ghost-motion.swift -o build/ghost-motion-test
build/ghost-motion-test
