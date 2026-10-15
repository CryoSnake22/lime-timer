#!/bin/bash
# Usage: ./build.sh            → builds build/QuickTimer.app
#        ./build.sh --install  → also copies it to ~/Applications and launches it
set -euo pipefail
cd "$(dirname "$0")"

APP=build/QuickTimer.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/"
[[ -f Resources/AppIcon.icns ]] || swift scripts/make_icon.swift
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/QuickTimer" Sources/main.swift
codesign --force -s - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x QuickTimer || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/QuickTimer.app
  cp -R "$APP" ~/Applications/
  open ~/Applications/QuickTimer.app
  echo "Installed to ~/Applications/QuickTimer.app"
fi
