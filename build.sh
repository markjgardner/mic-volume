#!/bin/zsh
# Builds Mic Volume.app, then installs it to ~/Applications and launches it.
# Usage: ./build.sh [--no-install]
set -euo pipefail
cd "${0:A:h}"

app="build/Mic Volume.app"
dest="$HOME/Applications/Mic Volume.app"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 \
  -o "$app/Contents/MacOS/MicVolume" Sources/*.swift
cp Info.plist "$app/Contents/Info.plist"

if [[ ! -f build/AppIcon.icns ]]; then
  iconset=build/AppIcon.iconset
  rm -rf "$iconset" && mkdir -p "$iconset"
  swift make_icon.swift build/icon_1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon_1024.png --out "$iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) build/icon_1024.png --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$iconset" -o build/AppIcon.icns
  rm -rf "$iconset" build/icon_1024.png
fi
cp build/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

codesign --force --sign - --identifier com.local.mic-volume "$app"
echo "Built $app"

[[ "${1:-}" == "--no-install" ]] && exit 0

pids=(${(f)"$(pgrep -x MicVolume || true)"})
if (( ${#pids} )); then
  kill $pids
  sleep 1
fi
mkdir -p "$HOME/Applications"
rm -rf "$dest"
ditto "$app" "$dest"
# Keep a single copy registered with LaunchServices so Open at login resolves to ~/Applications.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$PWD/$app" 2>/dev/null || true
rm -rf "$app"
open "$dest"
echo "Installed and launched $dest"
