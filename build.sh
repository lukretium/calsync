#!/bin/bash
# Baut CalSync.app (universal, ad-hoc signiert) nach build/.
set -euo pipefail
cd "$(dirname "$0")"
APP=build/CalSync.app
rm -rf build && mkdir -p "$APP/Contents/MacOS"
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos14" main.swift -o "build/calsync-$arch"
done
lipo -create build/calsync-arm64 build/calsync-x86_64 -output "$APP/Contents/MacOS/calsync"
rm build/calsync-*
cp Info.plist "$APP/Contents/Info.plist"
codesign --force -s - "$APP"
echo "gebaut: $APP"
