#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

cp "$ROOT_DIR/go2rtc.yaml" "$TEST_DIR/configured.yaml"
cat >> "$TEST_DIR/configured.yaml" <<'YAML'
# CAMERA_SERIAL remains a documented placeholder in this comment.
camera_serial_backup: CAMERA_SERIAL_SUFFIX
YAML
"$ROOT_DIR/configure-camera-serial.sh" \
  "$TEST_DIR/configured.yaml" "2400000000" >/dev/null

if grep -Ev '^[[:space:]]*#' "$TEST_DIR/configured.yaml" | \
    grep -v CAMERA_SERIAL_SUFFIX | grep -q CAMERA_SERIAL; then
  echo "Camera placeholder remained after configuration" >&2
  exit 1
fi

if ! grep -Fq '# CAMERA_SERIAL remains' "$TEST_DIR/configured.yaml" ||
   ! grep -Fq 'camera_serial_backup: CAMERA_SERIAL_SUFFIX' "$TEST_DIR/configured.yaml"; then
  echo "Camera configuration changed a comment or longer token" >&2
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

"$ROOT_DIR/add-camera-config.sh" \
  "$TEST_DIR/configured.yaml" "2400000001" "12344321" >/dev/null
section_has_camera() {
  section="$1"
  serial="$2"
  awk -v section="$section" -v serial="$serial" '
    $0 == section ":" { inside=1; next }
    inside && /^[^[:space:]#]/ { inside=0 }
    inside && $0 == "  \"" serial "\":" { found=1 }
    END { exit found ? 0 : 1 }
  ' "$TEST_DIR/configured.yaml"
}
if ! section_has_camera streams 2400000001 ||
   ! section_has_camera homekit 2400000001; then
  echo "Additional camera was not added to both streams and HomeKit" >&2
  exit 1
fi
if ! section_has_camera streams 2400000000 ||
   ! section_has_camera homekit 2400000000; then
  echo "Adding a camera removed or duplicated the existing camera" >&2
  exit 1
fi
"$ROOT_DIR/add-camera-config.sh" \
  "$TEST_DIR/configured.yaml" "2400000001" "12344321" >/dev/null
if [ "$(grep -Fc '"2400000001":' "$TEST_DIR/configured.yaml")" -ne 2 ]; then
  echo "Adding the same camera twice was not idempotent" >&2
  exit 1
fi

cat > "$TEST_DIR/separated.yaml" <<'YAML'
streams:
  "EXISTING":
    - ffmpeg:EXISTING#video=h264
api:
  listen: "127.0.0.1:1985"
homekit:
  "EXISTING":
    pin: 12344321
YAML
"$ROOT_DIR/add-camera-config.sh" \
  "$TEST_DIR/separated.yaml" "2400000002" "12344321" >/dev/null
if ! awk '
  /^streams:/ { in_streams=1; next }
  in_streams && /^[^[:space:]#]/ { exit found ? 0 : 1 }
  in_streams && /"2400000002":/ { found=1 }
  END { if (in_streams) exit found ? 0 : 1 }
' "$TEST_DIR/separated.yaml"; then
  echo "Additional camera escaped the streams mapping" >&2
  exit 1
fi

echo "Camera serial tests passed"
