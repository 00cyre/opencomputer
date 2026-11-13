#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
xcrun swiftc native/ApprovalPolicy.swift tests/approval-policy.swift -o build/approval-policy-test
build/approval-policy-test
