#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(node -p 'JSON.parse(require("fs").readFileSync("package.json")).version')"
mkdir -p dist build/package
STAGING="$(mktemp -d "$PWD/build/package/staging.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
for ARCH in arm64 x86_64; do
  OPENCOMPUTER_ARCH="$ARCH" OPENCOMPUTER_OUTPUT="$STAGING/helper-$ARCH" bash scripts/build.sh
done
lipo -create "$STAGING/helper-arm64" "$STAGING/helper-x86_64" -output build/opencomputer-native
codesign --force --sign - --identifier cc.opencomputer.helper build/opencomputer-native
codesign --verify --strict build/opencomputer-native
ROOT="$STAGING/opencomputer"
mkdir -p "$ROOT/build"
for ENTRY in bin src native scripts docs examples tests package.json README.md LICENSE SECURITY.md PRIVACY.md CHANGELOG.md AGENTS.md; do
  cp -R "$ENTRY" "$ROOT/$ENTRY"
done
cp build/opencomputer-native "$ROOT/build/"
ditto -c -k --sequesterRsrc --keepParent "$ROOT" "dist/OpenComputer-$VERSION-macOS.zip"
git archive --format=zip --prefix=opencomputer/ HEAD -o "dist/OpenComputer-$VERSION-source.zip"
(cd dist && shasum -a 256 "OpenComputer-$VERSION-macOS.zip" "OpenComputer-$VERSION-source.zip" > SHA256SUMS.txt)
lipo -archs build/opencomputer-native
