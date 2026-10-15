#!/bin/bash
# Builds the Mac App Store version, "Lime Timer". Completely separate from the dev QuickTimer build:
# different name, bundle ID (com.charlo.limetimer), settings, and output folder (build/appstore/).
#
# Usage: ./build-appstore.sh            → build/appstore/Lime Timer.app, sandboxed + ad-hoc signed, for local testing
#        ./build-appstore.sh --release  → signed for submission + build/appstore/LimeTimer.pkg (upload with Transporter)
#
# --release needs (create them in Xcode → Settings → Accounts → Manage Certificates, and the developer portal):
#   • an "Apple Distribution" certificate
#   • a "Mac Installer Distribution" certificate
#   • a Mac App Store provisioning profile for com.charlo.limetimer saved as appstore/embedded.provisionprofile
set -euo pipefail
cd "$(dirname "$0")"

TEAM_ID="Q654928MT3"
BUNDLE_ID="com.charlo.limetimer"
OUT=build/appstore
APP="$OUT/Lime Timer.app"

rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp appstore/Info.plist "$APP/Contents/"
[[ -f Resources/AppIcon.icns ]] || swift scripts/make_icon.swift
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# Universal binary (Apple Silicon + Intel), App Store variant (-D APPSTORE: public APIs only).
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -D APPSTORE -target "$arch-apple-macos13.0" -o "$OUT/LimeTimer-$arch" Sources/main.swift
done
lipo -create "$OUT/LimeTimer-arm64" "$OUT/LimeTimer-x86_64" -output "$APP/Contents/MacOS/LimeTimer"
rm "$OUT"/LimeTimer-arm64 "$OUT"/LimeTimer-x86_64

# Record the toolchain the way Xcode builds do; App Store Connect reads these keys.
PLIST="$APP/Contents/Info.plist"
SDK_VERSION=$(xcrun --sdk macosx --show-sdk-version)
SDK_BUILD=$(xcrun --sdk macosx --show-sdk-build-version)
XCODE_VERSION=$(xcodebuild -version | awk 'NR==1 {print $2}')   # e.g. 16.4
XCODE_BUILD=$(xcodebuild -version | awk 'NR==2 {print $3}')     # e.g. 16F6
DTXCODE=$(echo "$XCODE_VERSION" | awk -F. '{printf "%d%d%d", $1, $2, ($3 == "" ? 0 : $3)}') # 16.4 → 1640
for kv in "DTSDKName string macosx$SDK_VERSION" "DTSDKBuild string $SDK_BUILD" \
          "DTPlatformName string macosx" "DTPlatformVersion string $SDK_VERSION" "DTPlatformBuild string $SDK_BUILD" \
          "DTXcode string $DTXCODE" "DTXcodeBuild string $XCODE_BUILD" \
          "DTCompiler string com.apple.compilers.llvm.clang.1_0" \
          "BuildMachineOSBuild string $(sw_vers -buildVersion)"; do
  /usr/libexec/PlistBuddy -c "Add :$kv" "$PLIST"
done

xattr -cr "$APP" # App Store builds must not carry com.apple.quarantine

if [[ "${1:-}" == "--release" ]]; then
  PROFILE=appstore/embedded.provisionprofile
  [[ -f "$PROFILE" ]] || { echo "Missing $PROFILE (Mac App Store profile for $BUNDLE_ID)"; exit 1; }
  if grep -q "REPLACE-ME" Sources/main.swift; then
    echo "Set privacyPolicyURL in Sources/main.swift to the real hosted URL first."; exit 1
  fi
  cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"

  # Release entitlements = sandbox + the identifiers App Store signing requires.
  ENT="$OUT/release.entitlements"
  cp appstore/LimeTimer.entitlements "$ENT"
  /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $TEAM_ID.$BUNDLE_ID" "$ENT"
  /usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $TEAM_ID" "$ENT"

  codesign --force --sign "${APP_SIGN_ID:-Apple Distribution}" --entitlements "$ENT" "$APP"
  # The installer certificate is named "Mac Installer Distribution" (new) or "3rd Party Mac Developer Installer" (older).
  INSTALLER_ID="${INSTALLER_SIGN_ID:-$(security find-identity -v -p basic | grep -oE '"(Mac Installer Distribution|3rd Party Mac Developer Installer)[^"]*"' | head -1 | tr -d '"')}"
  [[ -n "$INSTALLER_ID" ]] || { echo "No Mac Installer Distribution certificate found"; exit 1; }
  productbuild --component "$APP" /Applications --sign "$INSTALLER_ID" "$OUT/LimeTimer.pkg"
  echo "Built $OUT/LimeTimer.pkg — upload it with Transporter (or: xcrun altool --upload-app)"
else
  codesign --force --sign - --entitlements appstore/LimeTimer.entitlements "$APP"
  echo "Built $APP (sandboxed, ad-hoc signed — for local testing only)"
fi
