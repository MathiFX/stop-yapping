#!/bin/bash
# Builds Stop Yapping for macOS: the menu bar app, the Stop Yapping Mic driver and a single .pkg installer.
#
# Optional environment:
#   VERSION              Version number (default: contents of mac/VERSION)
#   APP_SIGN_IDENTITY    "Developer ID Application: …" (default: ad-hoc signing)
#   PKG_SIGN_IDENTITY    "Developer ID Installer: …" (default: unsigned package)
#   NOTARY_PROFILE       notarytool keychain profile; notarizes and staples the package when set
set -euo pipefail

MAC_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$MAC_DIR")"
BUILD="$MAC_DIR/build"
OUT="$REPO_DIR/artifacts"
VERSION="${VERSION:-$(cat "$MAC_DIR/VERSION")}"
APP_SIGN_IDENTITY="${APP_SIGN_IDENTITY:--}"

# The virtual microphone is built from BlackHole by Existential Audio (GPL-3.0), pinned to a reviewed commit,
# and renamed as its license requires for modified builds.
BLACKHOLE_REPO="https://github.com/ExistentialAudio/BlackHole.git"
BLACKHOLE_COMMIT="6008d295ff00c8b57412a23564619963f4ecbeac"   # v0.7.1

rm -rf "$BUILD"
mkdir -p "$BUILD" "$OUT"

echo "==> Icon"
ICONSET="$BUILD/StopYapping.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$REPO_DIR/packaging/Assets/stop-yapping.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$REPO_DIR/packaging/Assets/stop-yapping.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$BUILD/StopYapping.icns"

echo "==> Stop Yapping Mic driver"
git clone --quiet "$BLACKHOLE_REPO" "$BUILD/blackhole"
git -C "$BUILD/blackhole" checkout --quiet "$BLACKHOLE_COMMIT"
# Device 1: the visible, input-only "Stop Yapping Mic" that call apps use.
# Device 2: a hidden, output-only twin that the app writes into.
xcodebuild -quiet \
  -project "$BUILD/blackhole/BlackHole.xcodeproj" \
  -configuration Release \
  -target BlackHole \
  CONFIGURATION_BUILD_DIR="$BUILD/driver" \
  SYMROOT="$BUILD/driver-sym" \
  OBJROOT="$BUILD/driver-obj" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  MACOSX_DEPLOYMENT_TARGET=10.13 \
  PRODUCT_NAME=StopYapping \
  PRODUCT_BUNDLE_IDENTIFIER=com.stopyapping.driver \
  MARKETING_VERSION="$VERSION" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  DEBUG_INFORMATION_FORMAT=dwarf \
  GCC_PREPROCESSOR_DEFINITIONS='$GCC_PREPROCESSOR_DEFINITIONS
    kDriver_Name=\"StopYapping\"
    kPlugIn_BundleID=\"com.stopyapping.driver\"
    kPlugIn_Icon=\"StopYapping.icns\"
    kManufacturer_Name=\"Stop\ Yapping\"
    kHas_Driver_Name_Format=false
    kDevice_Name=\"Stop\ Yapping\ Mic\"
    kDevice2_Name=\"Stop\ Yapping\ Feed\"
    kDevice_IsHidden=false
    kDevice_HasInput=true
    kDevice_HasOutput=false
    kDevice2_IsHidden=true
    kDevice2_HasInput=false
    kDevice2_HasOutput=true
    kNumber_Of_Channels=1
    kCanBeDefaultDevice=false
    kCanBeDefaultSystemDevice=false'
DRIVER="$BUILD/driver/StopYapping.driver"
# Use our own plug-in factory ID so the driver can sit next to an official BlackHole install.
FACTORY_UUID="c8e4ea65-fc65-4b1b-a676-f797c9eba916"
plutil -replace CFPlugInFactories -json "{\"$FACTORY_UUID\":\"BlackHole_Create\"}" "$DRIVER/Contents/Info.plist"
plutil -replace CFPlugInTypes -json "{\"443ABAB8-E7B3-491A-B985-BEB9187030DB\":[\"$FACTORY_UUID\"]}" "$DRIVER/Contents/Info.plist"
# Keep only our icon and the license; drop upstream branding and docs.
rm -f "$DRIVER/Contents/Resources/"{BlackHole.icns,README.md,CHANGELOG.md,VERSION}
cp "$BUILD/StopYapping.icns" "$DRIVER/Contents/Resources/StopYapping.icns"
codesign --force --timestamp=none --sign "$APP_SIGN_IDENTITY" "$DRIVER"

echo "==> App"
APP="$BUILD/Stop Yapping.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
for arch in arm64 x86_64; do
  swiftc -swift-version 5 -O -target "$arch-apple-macos13.0" \
    "$MAC_DIR"/Sources/*.swift -o "$BUILD/StopYapping-$arch"
done
lipo -create "$BUILD/StopYapping-arm64" "$BUILD/StopYapping-x86_64" -output "$APP/Contents/MacOS/StopYapping"
sed "s/__VERSION__/$VERSION/g" "$MAC_DIR/Info.plist" > "$APP/Contents/Info.plist"
cp "$BUILD/StopYapping.icns" "$APP/Contents/Resources/StopYapping.icns"
cp "$REPO_DIR/LICENSE" "$APP/Contents/Resources/LICENSE.txt"
cp "$MAC_DIR/THIRD-PARTY-NOTICES.txt" "$APP/Contents/Resources/THIRD-PARTY-NOTICES.txt"
codesign --force --options runtime --timestamp=none \
  --entitlements "$MAC_DIR/packaging/StopYapping.entitlements" \
  --sign "$APP_SIGN_IDENTITY" "$APP"
"$APP/Contents/MacOS/StopYapping" --self-test

echo "==> Installer"
export COPYFILE_DISABLE=1
mkdir -p "$BUILD/root-app/Applications" "$BUILD/root-driver"
ditto --norsrc --noextattr --noacl "$APP" "$BUILD/root-app/Applications/Stop Yapping.app"
ditto --norsrc --noextattr --noacl "$DRIVER" "$BUILD/root-driver/StopYapping.driver"
codesign --verify --strict --deep "$BUILD/root-app/Applications/Stop Yapping.app"
codesign --verify --strict "$BUILD/root-driver/StopYapping.driver"
pkgbuild --analyze --root "$BUILD/root-app" "$BUILD/app-components.plist" >/dev/null
plutil -replace 0.BundleIsRelocatable -bool NO "$BUILD/app-components.plist"
plutil -replace 0.BundleOverwriteAction -string upgrade "$BUILD/app-components.plist"
pkgbuild --root "$BUILD/root-app" --component-plist "$BUILD/app-components.plist" \
  --identifier com.stopyapping.app --version "$VERSION" --install-location / \
  --scripts "$MAC_DIR/packaging/scripts/app" "$BUILD/app.pkg" >/dev/null
pkgbuild --root "$BUILD/root-driver" \
  --identifier com.stopyapping.driver --version "$VERSION" --install-location /Library/Audio/Plug-Ins/HAL \
  --scripts "$MAC_DIR/packaging/scripts/driver" "$BUILD/driver.pkg" >/dev/null
sed "s/__VERSION__/$VERSION/g" "$MAC_DIR/packaging/Distribution.xml" > "$BUILD/Distribution.xml"

PKG="$OUT/StopYapping-$VERSION-macOS.pkg"
SIGN_ARGS=()
if [ -n "${PKG_SIGN_IDENTITY:-}" ]; then SIGN_ARGS=(--sign "$PKG_SIGN_IDENTITY"); fi
productbuild --distribution "$BUILD/Distribution.xml" --package-path "$BUILD" \
  --resources "$MAC_DIR/packaging/resources" ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} "$PKG" >/dev/null

if [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "==> Notarizing"
  xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$PKG"
fi

echo "==> Done: $PKG"
