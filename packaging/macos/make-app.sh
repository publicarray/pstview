#!/bin/sh
# make-app.sh <bin dir with pstview and pstx> <version> <output dir>: builds pstview.app (run on macOS).
# The app is ad-hoc signed, not notarised: after download, clear the quarantine flag (see README).
set -eu
bin=$1; version=$2; out=$3
here=$(cd "$(dirname "$0")" && pwd)
app="$out/pstview.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/pstview" "$bin/pstx" "$app/Contents/MacOS/"
sed "s/@VERSION@/$version/g" "$here/Info.plist" > "$app/Contents/Info.plist"
# icon: the PNGs in design/ as an .icns
set=$(mktemp -d)/pstview.iconset
mkdir -p "$set"
d="$here/../../design"
cp "$d/icon-16.png" "$set/icon_16x16.png"
cp "$d/icon-32.png" "$set/icon_16x16@2x.png"
cp "$d/icon-32.png" "$set/icon_32x32.png"
cp "$d/icon-64.png" "$set/icon_32x32@2x.png"
cp "$d/icon-128.png" "$set/icon_128x128.png"
cp "$d/icon-256.png" "$set/icon_128x128@2x.png"
cp "$d/icon-256.png" "$set/icon_256x256.png"
iconutil -c icns -o "$app/Contents/Resources/pstview.icns" "$set"
codesign --force --deep -s - "$app"
