#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

cp "$ROOT_DIR/go2rtc.yaml" "$TEST_DIR/configured.yaml"
"$ROOT_DIR/configure-camera-serial.sh" \
  "$TEST_DIR/configured.yaml" "2400000000" >/dev/null

if grep -Ev '^[[:space:]]*#' "$TEST_DIR/configured.yaml" | grep -q CAMERA_SERIAL; then
  echo "Camera placeholder remained after configuration" >&2
  exit 1
fi

if [ "$(grep -o '2400000000' "$TEST_DIR/configured.yaml" | wc -l | tr -d ' ')" -ne 3 ]; then
  echo "Camera serial was not written consistently" >&2
  exit 1
fi

cp "$ROOT_DIR/go2rtc.yaml" "$TEST_DIR/invalid.yaml"
if "$ROOT_DIR/configure-camera-serial.sh" \
  "$TEST_DIR/invalid.yaml" 'bad serial: value' >/dev/null 2>&1; then
  echo "Invalid camera serial was accepted" >&2
  exit 1
fi

cp "$ROOT_DIR/go2rtc.yaml" "$TEST_DIR/noninteractive.yaml"
if "$ROOT_DIR/configure-camera-serial.sh" \
  "$TEST_DIR/noninteractive.yaml" </dev/null >/dev/null 2>&1; then
  echo "Missing noninteractive camera serial was accepted" >&2
  exit 1
fi

echo "Camera serial tests passed"
