#!/usr/bin/env bash
# Replace the camera placeholder in a Harbor HomeKit configuration.
set -euo pipefail

CONFIG_PATH="${1:-}"
CAMERA_SERIAL="${2:-}"

usage() {
  echo "Usage: $0 path/to/go2rtc.yaml [camera-serial]" >&2
}

is_valid_camera_serial() {
  printf '%s\n' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{2,63}$'
}

if [ -z "$CONFIG_PATH" ] || [ ! -f "$CONFIG_PATH" ]; then
  usage
  exit 1
fi

if ! grep -Ev '^[[:space:]]*#' "$CONFIG_PATH" | grep -q 'CAMERA_SERIAL'; then
  echo "Camera serial is already configured in $CONFIG_PATH."
  exit 0
fi

while ! is_valid_camera_serial "$CAMERA_SERIAL"; do
  if [ -n "$CAMERA_SERIAL" ]; then
    echo "Invalid camera serial: use 3-64 letters, numbers, periods, underscores, or hyphens." >&2
  fi
  if [ ! -t 0 ]; then
    echo "A camera serial is required for noninteractive installation." >&2
    usage
    exit 1
  fi
  printf 'Enter your Harbor camera serial number: '
  IFS= read -r CAMERA_SERIAL
done

configured="$(mktemp "${CONFIG_PATH}.camera.XXXXXX")"
cleanup() {
  rm -f "$configured"
}
trap cleanup EXIT

LC_ALL=C CAMERA_SERIAL_VALUE="$CAMERA_SERIAL" perl -pe '
  if (!/^[[:space:]]*#/) {
    s/\bCAMERA_SERIAL\b/$ENV{CAMERA_SERIAL_VALUE}/g;
  }
' "$CONFIG_PATH" > "$configured"
chmod 600 "$configured"
mv "$configured" "$CONFIG_PATH"
trap - EXIT

echo "Configured Harbor camera: $CAMERA_SERIAL"
