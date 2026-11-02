#!/bin/sh
set -eu
cd "$(dirname "$0")"
app="build/Magic Pinch.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Info.plist "$app/Contents/Info.plist"
cp LICENSE "$app/Contents/Resources/LICENSE"
cp THIRD_PARTY_NOTICES.txt "$app/Contents/Resources/THIRD_PARTY_NOTICES.txt"
cp Assets/MagicPinch-balanced.icns "$app/Contents/Resources/MagicPinch.icns"
clang -fobjc-arc -fblocks -O2 -Wall -Wextra \
  -framework AppKit -framework ApplicationServices -framework CoreServices -framework ServiceManagement \
  main.m -o "$app/Contents/MacOS/MagicPinch"
codesign --force --sign - "$app"
"$app/Contents/MacOS/MagicPinch" --self-test
