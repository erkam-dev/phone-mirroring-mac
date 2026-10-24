#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

echo "==> Compiling native Swift binary..."
swiftc -O Sources/main.swift -o Contents/MacOS/PhoneMirroring

echo "==> Updating app bundle..."
APP_DEST="$HOME/Applications/Phone Mirroring.app"
rm -rf "$APP_DEST"
mkdir -p "$APP_DEST"
cp -R Contents "$APP_DEST/"
chmod +x "$APP_DEST/Contents/MacOS/PhoneMirroring"
touch "$APP_DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DEST"

echo "==> Done! App built and installed at $APP_DEST"
