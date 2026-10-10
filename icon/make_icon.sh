#!/bin/bash
# Rebuilds KIMLAB.icns from kimlab.svg.
cd "$(dirname "$0")"
echo running > status
FLAGS="-swift-version 5 -target arm64-apple-macosx15.0"
[ -f ../build/overlay.yaml ] && FLAGS="$FLAGS -vfsoverlay ../build/overlay.yaml"
(cd .. && swiftc ${FLAGS//..\/build/build} icon/make_icon.swift -o build/make_icon) > log.txt 2>&1 || { echo "done 1" > status; exit 1; }
../build/make_icon "$PWD" >> log.txt 2>&1 || { echo "done 2" > status; exit 2; }
rm -rf KIMLAB.iconset && mkdir KIMLAB.iconset
for s in 16 32 128 256 512; do
  sips -z $s $s KIMLAB-1024.png --out KIMLAB.iconset/icon_${s}x${s}.png > /dev/null
  d=$((s * 2))
  sips -z $d $d KIMLAB-1024.png --out KIMLAB.iconset/icon_${s}x${s}@2x.png > /dev/null
done
iconutil -c icns KIMLAB.iconset -o KIMLAB.icns >> log.txt 2>&1
echo "done $?" > status
