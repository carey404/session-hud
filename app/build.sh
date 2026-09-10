#!/bin/zsh
# Builds app/build/SessionHUD.app with clang (no Xcode needed).
set -e
cd "$(dirname "$0")"
OUT=build/SessionHUD.app/Contents
rm -rf build && mkdir -p "$OUT/MacOS" "$OUT/Resources"
clang -fobjc-arc -fmodules -Wall -Wno-unused -O1 -framework Cocoa main.m -o "$OUT/MacOS/SessionHUD"
cp Info.plist "$OUT/Info.plist"
codesign --force --sign - "build/SessionHUD.app" >/dev/null 2>&1 || true
echo "built $(pwd)/build/SessionHUD.app"
