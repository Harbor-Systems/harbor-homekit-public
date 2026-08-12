#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

for script in ./*.sh ./scripts/*.sh ./tests/*.sh; do
  bash -n "$script"
done

if [ "$(grep -o 'CAMERA_SERIAL' go2rtc.yaml | wc -l | tr -d ' ')" -ne 3 ]; then
  echo "go2rtc.yaml must use CAMERA_SERIAL consistently in three places" >&2
  exit 1
fi

if grep -Eq 'alexxit/go2rtc:latest' docker-compose.yml; then
  echo "Docker image must be pinned to a release" >&2
  exit 1
fi

if grep -Eq 'releases/latest|GO2RTC_VERSION:-latest' run-native.sh; then
  echo "Native runner must not download an unpinned latest release" >&2
  exit 1
fi

homekit_boundary_text='homekit_listen: ":21063"'
for boundary_file in go2rtc.yaml run-native.sh; do
  if ! grep -Fq "$homekit_boundary_text" "$boundary_file"; then
    echo "$boundary_file is missing the HomeKit pairing listener boundary" >&2
    exit 1
  fi
done

if [ ! -s patches/go2rtc-1.9.14-homekit-lan-listener.patch ]; then
  echo "The HomeKit LAN listener patch is missing" >&2
  exit 1
fi

# shellcheck disable=SC2016 # literal grep pattern, not an expansion
if ! grep -Fq 'for patch in "$ROOT_DIR"/patches/*.patch' scripts/build-go2rtc.sh; then
  echo "go2rtc build must apply every versioned patch" >&2
  exit 1
fi

if [ "$(awk -F= '/^HARBOR_HOMEKIT_RELEASE=/{print $2}' scripts/versions.env)" != "v0.5.2" ]; then
  echo "Native installer must use the signed and notarized v0.5.2 release" >&2
  exit 1
fi

for required_homekit_patch_text in \
  'net.Listen("tcp", cfg.Listen)' \
  'ReadHeaderTimeout: 10 * time.Second'; do
  if ! grep -Fq "$required_homekit_patch_text" patches/go2rtc-1.9.14-homekit-lan-listener.patch; then
    echo "HomeKit LAN listener patch is missing: $required_homekit_patch_text" >&2
    exit 1
  fi
done

if ! grep -Fq "[ \"\$os_tag\" = \"mac\" ] && [ ! -x \"\$LAUNCHER_BIN\" ]" run-native.sh; then
  echo "Native runner must download a missing macOS bridge launcher" >&2
  exit 1
fi

# A fresh v0.5+ template must pass the installer's hardened-config check. Keep
# these strings identical so the installer never rejects its own config as
# customer customization.
required_api_allowlist='allow_paths: [/api/streams, /api/webrtc, /api/preload]'
if ! grep -Fq "$required_api_allowlist" go2rtc.yaml ||
   [ "$(grep -Fc "$required_api_allowlist" install-macos-service.sh)" -ne 2 ]; then
  echo "Installer and template API allowlists are out of sync" >&2
  exit 1
fi

if ! grep -Fq '<string>0.5.2</string>' scripts/build-macos-setup-app.sh; then
  echo "macOS app version must match release v0.5.2" >&2
  exit 1
fi

for required_setup_safety_text in \
  'installedSetupCode = ""' \
  '"-sTCP:LISTEN"' \
  'readDataToEndOfFile()' \
  'NWBrowser(for: .bonjour(type: "_hap._tcp"' \
  'replaceItemAt(destination, withItemAt: staging)'; do
  if ! grep -Fq "$required_setup_safety_text" macos/HarborHomeKitSetup.swift; then
    echo "macOS bridge UI is missing safety behavior: $required_setup_safety_text" >&2
    exit 1
  fi
done

setup_bundle_id="$(sed -n 's|.*CFBundleIdentifier</key><string>\([^<]*\)</string>.*|\1|p' scripts/build-macos-setup-app.sh | head -1)"
background_bundle_id="$(sed -n 's/^APP_BUNDLE_ID="\([^"]*\)"$/\1/p' install-macos-service.sh | head -1)"
if [ -z "$setup_bundle_id" ] || [ "$setup_bundle_id" != "$background_bundle_id" ]; then
  echo "Setup and background bridge must share the Local Network bundle ID" >&2
  exit 1
fi

if ! grep -Fq '<key>NSBonjourServices</key><array><string>_hap._tcp</string></array>' \
  scripts/build-macos-setup-app.sh; then
  echo "Setup app must declare the HomeKit Bonjour service" >&2
  exit 1
fi

if [ ! -s macos/HarborLogo.png ] || \
   ! grep -Fq 'macos/HarborLogo.png' scripts/build-macos-setup-dmg.sh; then
  echo "DMG renderer must use the committed PNG wordmark" >&2
  exit 1
fi

if ! grep -Fq 'shasum -a 256 -- *.zip *.dmg > checksums.txt' .github/workflows/release.yml; then
  echo "Release checksums must use archive basenames" >&2
  exit 1
fi

if grep -R -nE '^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*[^[:space:]@]+@[^[:space:]#]+' \
    .github/workflows | grep -Ev '@[0-9a-fA-F]{40}([[:space:]]*#.*)?$'; then
  echo "GitHub Actions must be pinned to immutable commit SHAs" >&2
  exit 1
fi

for required_provenance_text in \
  'environment: release' \
  'id-token: write' \
  'attestations: write' \
  'name: Attest release provenance' \
  'actions/attest-build-provenance@43d14bc2b83dec42d39ecae14e916627a18bb661'; do
  if ! grep -Fq "$required_provenance_text" .github/workflows/release.yml; then
    echo "Release workflow is missing provenance control: $required_provenance_text" >&2
    exit 1
  fi
done

for setup_app_text in \
  'scripts/build-macos-setup-app.sh' \
  'scripts/build-macos-setup-dmg.sh' \
  'dist/Harbor HomeKit Bridge.app' \
  'dist/Harbor-HomeKit-Bridge.dmg'; do
  if ! grep -Fq "$setup_app_text" .github/workflows/release.yml; then
    echo "Release workflow is missing setup application step: $setup_app_text" >&2
    exit 1
  fi
done

# shellcheck disable=SC2016 # literal grep pattern, not an expansion
for dmg_layout_text in \
  'ln -s /Applications "$staging/Applications"' \
  'RenderDMGBackground.swift' \
  'set background picture of view_options'; do
  if ! grep -Fq "$dmg_layout_text" scripts/build-macos-setup-dmg.sh; then
    echo "Disk image script is missing drag-to-install layout: $dmg_layout_text" >&2
    exit 1
  fi
done

if [ "$(grep -Ec '^FROM [^ ]+@sha256:[0-9a-f]{64}([[:space:]]|$)' Dockerfile)" -ne 2 ]; then
  echo "Every Docker build stage must use an immutable image digest" >&2
  exit 1
fi

for required_release_text in \
  'name: Sign macOS binaries' \
  'codesign --force --options runtime --timestamp' \
  'name: Notarize macOS archives' \
  'xcrun notarytool submit' \
  'xcrun stapler staple "dist/Harbor-HomeKit-Bridge.dmg"'; do
  if ! grep -Fq "$required_release_text" .github/workflows/release.yml; then
    echo "Release workflow is missing: $required_release_text" >&2
    exit 1
  fi
done

if grep -Eq 'Optionally (sign|notarize)|^[[:space:]]+if:' .github/workflows/release.yml; then
  echo "macOS release signing and notarization must fail closed" >&2
  exit 1
fi

for expected in \
  'Developer ID Application: Project Monitor, Inc. (TC395YUVC2)' \
  'EXPECTED_APPLE_TEAM="TC395YUVC2"' \
  "TeamIdentifier=\$EXPECTED_APPLE_TEAM"; do
  if ! grep -Fq "$expected" run-native.sh; then
    echo "Native runner is missing Apple signature verification: $expected" >&2
    exit 1
  fi
done

if [ "$(grep -c 'verify_macos_binary "' run-native.sh)" -ne 5 ]; then
  echo "Native runner must verify both extracted and installed macOS binaries" >&2
  exit 1
fi

if ! grep -q 'Project Monitor Inc.' LICENSE; then
  echo "MIT license copyright holder is missing" >&2
  exit 1
fi

go test ./...
./tests/test-pin-generation.sh
./tests/test-camera-serial.sh
./tests/test-checksum-manifest.sh
echo "Repository tests passed"
