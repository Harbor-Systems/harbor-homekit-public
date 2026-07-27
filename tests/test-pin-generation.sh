#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

cp "$ROOT_DIR/go2rtc.yaml" "$TEST_DIR/generated.yaml"
first_output="$("$ROOT_DIR/generate-homekit-pin.sh" "$TEST_DIR/generated.yaml")"
first_pin="$(awk '/^[[:space:]]+pin:/{print $2; exit}' "$TEST_DIR/generated.yaml")"

if ! printf '%s\n' "$first_output" | grep -Eq \
    'HomeKit setup code: [0-9]{3}-[0-9]{2}-[0-9]{3}'; then
  echo "Generator did not print a formatted setup code" >&2
  exit 1
fi

if ! printf '%s\n' "$first_pin" | grep -Eq '^[0-9]{8}$'; then
  echo "Generator did not persist an eight-digit PIN" >&2
  exit 1
fi

"$ROOT_DIR/generate-homekit-pin.sh" "$TEST_DIR/generated.yaml" >/dev/null
second_pin="$(awk '/^[[:space:]]+pin:/{print $2; exit}' "$TEST_DIR/generated.yaml")"
if [ "$first_pin" != "$second_pin" ]; then
  echo "Generator did not preserve an existing PIN" >&2
  exit 1
fi

cat > "$TEST_DIR/missing.yaml" <<'YAML'
homekit:
  CAMERA_SERIAL:
    name: Harbor Camera
YAML

if "$ROOT_DIR/generate-homekit-pin.sh" "$TEST_DIR/missing.yaml" >/dev/null 2>&1; then
  echo "Generator accepted a config without a pin setting" >&2
  exit 1
fi

mode="$(stat -f '%Lp' "$TEST_DIR/generated.yaml" 2>/dev/null || stat -c '%a' "$TEST_DIR/generated.yaml")"
if [ "$mode" != "600" ]; then
  echo "Generated config mode is $mode, expected 600" >&2
  exit 1
fi

echo "PIN generation tests passed"
