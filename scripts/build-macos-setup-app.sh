#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
output="${1:-$root/dist/Harbor HomeKit Bridge.app}"
contents="$output/Contents"

rm -rf "$output"
mkdir -p "$contents/MacOS" "$contents/Resources/installer"

build_dir="$(mktemp -d)"
trap 'rm -rf "$build_dir"' EXIT
for arch in arm64 x86_64; do
  swiftc \
    -parse-as-library \
    -target "$arch-apple-macos13.0" \
    -framework SwiftUI \
    -framework AppKit \
    "$root/macos/HarborHomeKitSetup.swift" \
    -o "$build_dir/setup-$arch"
done
lipo -create "$build_dir/setup-arm64" "$build_dir/setup-x86_64" \
  -output "$contents/MacOS/Harbor HomeKit Bridge"

cp "$root/install-macos-service.sh" "$contents/Resources/installer/"
cp "$root/configure-camera-serial.sh" "$contents/Resources/installer/"
cp "$root/add-camera-config.sh" "$contents/Resources/installer/"
cp "$root/generate-homekit-pin.sh" "$contents/Resources/installer/"
cp "$root/run-native.sh" "$contents/Resources/installer/"
cp "$root/go2rtc.yaml" "$contents/Resources/installer/"
if [ -x "$root/harbor-whip-gateway" ]; then
  cp "$root/harbor-whip-gateway" "$contents/Resources/installer/"
fi
cp "$root/macos/HarborLogo.png" "$contents/Resources/"
mkdir -p "$contents/Resources/installer/scripts"
cp "$root/scripts/versions.env" "$contents/Resources/installer/scripts/"

iconset="$build_dir/HarborHomeKit.iconset"
icon_source="$build_dir/HarborAppIcon.png"
base64 -D < "$root/macos/HarborAppIcon.png.b64" > "$icon_source"
mkdir -p "$iconset"
for points in 16 32 128 256 512; do
  sips -s format png -z "$points" "$points" "$icon_source" \
    --out "$iconset/icon_${points}x${points}.png" >/dev/null
  pixels="$((points * 2))"
  sips -s format png -z "$pixels" "$pixels" "$icon_source" \
    --out "$iconset/icon_${points}x${points}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$contents/Resources/HarborHomeKit.icns"

cat > "$contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>Harbor HomeKit Bridge</string>
  <key>CFBundleIdentifier</key><string>co.harbor.homekit.bridge.setup</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Harbor HomeKit Bridge</string>
  <key>CFBundleDisplayName</key><string>Harbor HomeKit Bridge Setup</string>
  <key>CFBundleIconFile</key><string>HarborHomeKit</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.5.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSLocalNetworkUsageDescription</key><string>Harbor HomeKit Bridge connects your Harbor camera to this Mac on your local network.</string>
</dict></plist>
PLIST

chmod 755 "$contents/MacOS/Harbor HomeKit Bridge" "$contents/Resources/installer/"*.sh
