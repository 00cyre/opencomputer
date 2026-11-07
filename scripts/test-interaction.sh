#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
xcrun swiftc native/InteractionPolicy.swift tests/interaction-policy.swift -o build/interaction-policy-test
build/interaction-policy-test
