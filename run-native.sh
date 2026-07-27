#!/usr/bin/env bash
# Download and run the native go2rtc binary against ./go2rtc.yaml.
# Recommended path on macOS, where Docker can't advertise HomeKit over mDNS.
set -euo pipefail

cd "$(dirname "$0")"

BIN="./go2rtc"
REPOSITORY="Harbor-Systems/harbor-homekit-public"
# shellcheck disable=SC1091
source ./scripts/versions.env
RELEASE="${HARBOR_HOMEKIT_RELEASE_OVERRIDE:-$HARBOR_HOMEKIT_RELEASE}"

# Replace the template sentinel on first run and preserve the resulting PIN.
./generate-homekit-pin.sh ./go2rtc.yaml

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

if [ ! -x "$BIN" ]; then
  base_url="https://github.com/${REPOSITORY}/releases/download/${RELEASE}"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  echo "Downloading Harbor's pinned go2rtc build ($RELEASE)..."
  curl -fL "$base_url/$asset" -o "$tmp/$asset"
  curl -fL "$base_url/checksums.txt" -o "$tmp/checksums.txt"
  expected_line="$(grep "  $asset\$" "$tmp/checksums.txt" || true)"
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
  mv "$tmp/unpacked/go2rtc" "$BIN"
  chmod +x "$BIN"
fi

# ffmpeg is needed for transcoding fallbacks. Warn if missing.
if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "WARNING: ffmpeg not found on PATH. Install it (brew install ffmpeg) if"
  echo "         your publisher sends non-H264/OPUS codecs." >&2
fi

exec "$BIN" -config go2rtc.yaml
