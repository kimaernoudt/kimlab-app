#!/bin/bash
# Builds KIMLAB.app next to this script. Needs only Apple's Command Line Tools (no Xcode).
#   ./build.sh         build the app
#   ./build.sh check   type-check only (faster)
cd "$(dirname "$0")"
mkdir -p build
FLAGS="-swift-version 5 -target arm64-apple-macosx15.0 -parse-as-library"
INC=/Library/Developer/CommandLineTools/usr/include/swift
# An older Command Line Tools version can leave a stale module map behind that breaks every Swift build.
# It is hidden for this build only; nothing on the system is changed.
if [ -f "$INC/module.modulemap" ] && [ -f "$INC/bridging.modulemap" ]; then
  : > build/empty.modulemap
  cat > build/overlay.yaml <<EOF
{ "version": 0, "case-sensitive": "false", "roots": [
  { "name": "$INC", "type": "directory",
    "contents": [ { "name": "module.modulemap", "type": "file", "external-contents": "$PWD/build/empty.modulemap" } ] } ] }
EOF
  FLAGS="$FLAGS -vfsoverlay build/overlay.yaml"
fi
MODE="${1:-build}"
echo "running" > build/status
if [ "$MODE" = "check" ]; then
  swiftc -typecheck $FLAGS Sources/KIMLAB/*.swift > build/build.log 2>&1
else
  swiftc -O $FLAGS Sources/KIMLAB/*.swift -o build/KIMLAB > build/build.log 2>&1
fi
STATUS=$?
if [ $STATUS -eq 0 ] && [ "$MODE" != "check" ]; then
  APP=KIMLAB.app
  mkdir -p "$APP/Contents/MacOS"
  cp -f build/KIMLAB "$APP/Contents/MacOS/KIMLAB.new" && mv -f "$APP/Contents/MacOS/KIMLAB.new" "$APP/Contents/MacOS/KIMLAB"
  cp -f Info.plist "$APP/Contents/Info.plist"
  mkdir -p "$APP/Contents/Resources"
  [ -f icon/KIMLAB.icns ] && cp -f icon/KIMLAB.icns "$APP/Contents/Resources/KIMLAB.icns"
  codesign --force -s - "$APP" >> build/build.log 2>&1
fi
echo "done $STATUS" > build/status
