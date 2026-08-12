#!/usr/bin/env bash
# Download and run the native go2rtc binary against ./go2rtc.yaml.
# Recommended path on macOS, where Docker can't advertise HomeKit over mDNS.
# shellcheck disable=SC2317 # Cleanup is invoked indirectly by signal traps.
set -euo pipefail

select_checksum_line() {
  manifest="$1"
  archive="$2"
  awk -v asset="$archive" '$2 == asset || $2 == "./" asset { print; exit }' "$manifest"
}

# Internal test hook: exercise the exact manifest parser without starting the bridge.
if [ "${HARBOR_CHECKSUM_LOOKUP_ONLY:-0}" = "1" ]; then
  select_checksum_line "$1" "$2"
  exit
fi

cd "$(dirname "$0")"

BIN="./go2rtc"
GATEWAY_BIN="./harbor-whip-gateway"
LAUNCHER_BIN="./harbor-bridge-launcher"
TOKEN_FILE="./.harbor-whip-token"
STATUS_FILE="./.harbor-whip-connected"
REPOSITORY="Harbor-Systems/harbor-homekit-public"
# shellcheck disable=SC1091
source ./scripts/versions.env
RELEASE="${HARBOR_HOMEKIT_RELEASE_OVERRIDE:-$HARBOR_HOMEKIT_RELEASE}"
EXPECTED_APPLE_AUTHORITY="Developer ID Application: Project Monitor, Inc. (TC395YUVC2)"
EXPECTED_APPLE_TEAM="TC395YUVC2"

verify_macos_binary() {
  binary="$1"
  details="$(codesign -dv --verbose=4 "$binary" 2>&1)" || {
    echo "Invalid or missing Apple signature: $binary" >&2
    return 1
  }
  codesign --verify --strict --verbose=2 "$binary"
  printf '%s\n' "$details" | grep -Fqx "Authority=$EXPECTED_APPLE_AUTHORITY" || {
    echo "Unexpected Apple signing identity: $binary" >&2
    return 1
  }
  printf '%s\n' "$details" | grep -Fqx "TeamIdentifier=$EXPECTED_APPLE_TEAM" || {
    echo "Unexpected Apple signing team: $binary" >&2
    return 1
  }
}

# Replace the template sentinel on first run and preserve the resulting PIN.
./generate-homekit-pin.sh ./go2rtc.yaml

if ! grep -Fq 'listen: "127.0.0.1:1985"' go2rtc.yaml ||
   ! grep -Fq 'listen: "127.0.0.1:8554"' go2rtc.yaml ||
   ! grep -Fq 'allow_paths: [/api/streams, /api/webrtc, /api/preload]' go2rtc.yaml ||
   ! grep -Fq 'allow_paths: [ffmpeg]' go2rtc.yaml ||
   ! grep -Fq 'homekit_listen: ":21063"' go2rtc.yaml; then
  echo "go2rtc.yaml does not contain Harbor's required security settings." >&2
  echo "Merge the hardened blocks from the repository template before running." >&2
  exit 1
fi

# Map platform -> release asset name.
os="$(uname -s)"
arch="$(uname -m)"
case "$os" in
  Darwin) os_tag="mac" ;;
  Linux)  os_tag="linux" ;;
  *) echo "Unsupported OS: $os" >&2; exit 1 ;;
esac
case "$arch" in
  arm64|aarch64) arch_tag="arm64" ;;
  x86_64|amd64)  arch_tag="amd64" ;;
  *) echo "Unsupported arch: $arch" >&2; exit 1 ;;
esac
asset="harbor-homekit-go2rtc_${os_tag}_${arch_tag}.zip"

if [ ! -x "$BIN" ] || [ ! -x "$GATEWAY_BIN" ] || \
   { [ "$os_tag" = "mac" ] && [ ! -x "$LAUNCHER_BIN" ]; }; then
  base_url="https://github.com/${REPOSITORY}/releases/download/${RELEASE}"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  echo "Downloading Harbor's pinned go2rtc build ($RELEASE)..."
  curl -fsSL "$base_url/$asset" -o "$tmp/$asset"
  curl -fsSL "$base_url/checksums.txt" -o "$tmp/checksums.txt"
  expected_line="$(select_checksum_line "$tmp/checksums.txt" "$asset")"
  if [ -z "$expected_line" ]; then
    echo "No checksum found for $asset" >&2
    exit 1
  fi
  expected_hash="${expected_line%% *}"
  if command -v shasum >/dev/null 2>&1; then
    actual_hash="$(shasum -a 256 "$tmp/$asset" | awk '{print $1}')"
  else
    actual_hash="$(sha256sum "$tmp/$asset" | awk '{print $1}')"
  fi
  if [ "$actual_hash" != "$expected_hash" ]; then
    echo "Checksum verification failed for $asset" >&2
    exit 1
  fi
  unzip -oq "$tmp/$asset" -d "$tmp/unpacked"
  if [ "$os_tag" = "mac" ]; then
    verify_macos_binary "$tmp/unpacked/go2rtc"
    verify_macos_binary "$tmp/unpacked/harbor-whip-gateway"
  fi
  mv "$tmp/unpacked/go2rtc" "$BIN"
  mv "$tmp/unpacked/harbor-whip-gateway" "$GATEWAY_BIN"
  chmod +x "$BIN" "$GATEWAY_BIN"
  # macOS releases since the app-bundle restructure also ship the launcher
  # that "Harbor HomeKit Bridge.app" wraps for Local Network attribution.
  if [ -f "$tmp/unpacked/harbor-bridge-launcher" ]; then
    if [ "$os_tag" = "mac" ]; then
      verify_macos_binary "$tmp/unpacked/harbor-bridge-launcher"
    fi
    mv "$tmp/unpacked/harbor-bridge-launcher" "$LAUNCHER_BIN"
    chmod +x "$LAUNCHER_BIN"
  fi
fi

if [ "$os_tag" = "mac" ]; then
  verify_macos_binary "$BIN"
  verify_macos_binary "$GATEWAY_BIN"
fi

if [ ! -x "$GATEWAY_BIN" ]; then
  echo "Harbor WHIP gateway is missing. Remove ./go2rtc and rerun to download" >&2
  echo "the complete pinned release, or build the gateway from source." >&2
  exit 1
fi

# The installer materializes binaries up front with this hook so the app
# bundle can be assembled before the service ever starts.
if [ "${HARBOR_DOWNLOAD_ONLY:-0}" = "1" ]; then
  exit 0
fi

# ffmpeg is needed for transcoding fallbacks. Warn if missing.
if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "WARNING: ffmpeg not found on PATH. Install it (brew install ffmpeg) if"
  echo "         your publisher sends non-H264/OPUS codecs." >&2
fi

stream_names="$(
  awk '
    /^streams:/ { in_streams=1; next }
    in_streams && /^[^[:space:]#]/ { exit }
    in_streams && /^[[:space:]]+"[^"]+":/ {
      line=$0
      sub(/^[[:space:]]+"/, "", line)
      sub(/":.*/, "", line)
      print line
    }
  ' go2rtc.yaml
)"
if [ -z "$stream_names" ] || printf '%s\n' "$stream_names" | grep -Fxq 'CAMERA_SERIAL'; then
  echo "Could not determine the configured Harbor camera serial." >&2
  exit 1
fi
stream_list="$(printf '%s\n' "$stream_names" | paste -sd, -)"

if [ ! -f "$TOKEN_FILE" ]; then
  umask 077
  od -An -N32 -tx1 /dev/urandom | tr -d '[:space:]' > "$TOKEN_FILE"
fi
chmod 600 "$TOKEN_FILE"
rm -f "$STATUS_FILE".*

go2rtc_pid=""
gateway_pid=""
# shellcheck disable=SC2329 # Invoked by the EXIT/INT/TERM trap below.
cleanup() {
  trap - EXIT INT TERM
  [ -z "$gateway_pid" ] || kill "$gateway_pid" >/dev/null 2>&1 || true
  [ -z "$go2rtc_pid" ] || kill "$go2rtc_pid" >/dev/null 2>&1 || true
  [ -z "$gateway_pid" ] || wait "$gateway_pid" >/dev/null 2>&1 || true
  [ -z "$go2rtc_pid" ] || wait "$go2rtc_pid" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

"$BIN" -config go2rtc.yaml &
go2rtc_pid="$!"
HARBOR_WHIP_TOKEN_FILE="$TOKEN_FILE" \
HARBOR_WHIP_STREAMS="$stream_list" \
HARBOR_WHIP_STATUS_FILE="$STATUS_FILE" \
HARBOR_GO2RTC_URL="http://127.0.0.1:1985" \
  "$GATEWAY_BIN" &
gateway_pid="$!"

# Bash 3.2 ships with macOS and has no `wait -n`, so supervise both children.
while kill -0 "$go2rtc_pid" >/dev/null 2>&1 && \
      kill -0 "$gateway_pid" >/dev/null 2>&1; do
  sleep 2
done
echo "Harbor HomeKit stopped because a required process exited." >&2
exit 1
