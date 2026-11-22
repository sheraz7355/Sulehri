#!/bin/zsh
set -e
cd "$(dirname "$0")"
APP=Sulehri.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
swiftc -O -swift-version 5 -o $APP/Contents/MacOS/Sulehri main.swift palette.swift \
  -framework Cocoa -framework AVFoundation -framework Speech -framework WebKit 2>&1 | grep -E "error" || true
test -f $APP/Contents/MacOS/Sulehri
cp Info.plist $APP/Contents/Info.plist
cp board.html tts_server.py SULEHRI.md $APP/Contents/Resources/
# Sign with the permanent local identity so macOS remembers Sulehri's permissions across rebuilds.
if security find-certificate -c "Sulehri Local Signing" >/dev/null 2>&1; then
  codesign --force --deep -s "Sulehri Local Signing" $APP
else
  codesign --force --deep -s - $APP
fi
# The `mac` helper Sulehri uses to click and type for you.
mkdir -p ~/.local/bin && cp mac ~/.local/bin/mac && chmod +x ~/.local/bin/mac
echo "Built $(pwd)/$APP"
