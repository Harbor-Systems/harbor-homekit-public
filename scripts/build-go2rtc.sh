#!/usr/bin/env bash
# Reproducibly build the pinned go2rtc source with Harbor's macOS mDNS patch.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/versions.env"

TARGET_OS="${1:-$(go env GOOS)}"
TARGET_ARCH="${2:-$(go env GOARCH)}"
OUTPUT="${3:-$ROOT_DIR/go2rtc}"
BUILD_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$BUILD_DIR"
}
trap cleanup EXIT

git clone --quiet --branch "$GO2RTC_TAG" --depth 1 \
  https://github.com/AlexxIT/go2rtc.git "$BUILD_DIR/go2rtc"

actual_commit="$(git -C "$BUILD_DIR/go2rtc" rev-parse HEAD)"
if [ "$actual_commit" != "$GO2RTC_COMMIT" ]; then
  echo "Unexpected go2rtc commit for $GO2RTC_TAG: $actual_commit" >&2
  exit 1
fi

git -C "$BUILD_DIR/go2rtc" apply \
  "$ROOT_DIR/patches/go2rtc-1.9.14-macos-mdns.patch"

(
  cd "$BUILD_DIR/go2rtc"
  CGO_ENABLED=0 GOOS="$TARGET_OS" GOARCH="$TARGET_ARCH" \
    go build -trimpath -buildvcs=false \
      -ldflags="-buildid=" \
      -o "$OUTPUT" .
)

chmod 700 "$OUTPUT"
echo "Built $OUTPUT for $TARGET_OS/$TARGET_ARCH from $GO2RTC_COMMIT"
