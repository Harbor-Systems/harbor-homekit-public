#!/usr/bin/env bash
# Generate and persist a unique HomeKit setup PIN in a go2rtc YAML config.
set -euo pipefail

CONFIG="${1:-./go2rtc.yaml}"

is_valid_pin() {
  case "$1" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;;
    *) return 1 ;;
  esac

  case "$1" in
    00000000|11111111|22222222|33333333|44444444|55555555|66666666|77777777|88888888|99999999|12345678|87654321)
      return 1
      ;;
  esac
}

if [ ! -f "$CONFIG" ]; then
  echo "Config not found: $CONFIG" >&2
  exit 1
fi

if ! grep -Eq '^[[:space:]]+pin:' "$CONFIG"; then
  echo "HomeKit pin setting not found in: $CONFIG" >&2
  exit 1
fi

pin="$(awk '/^[[:space:]]+pin:/{gsub(/[^0-9]/, "", $2); print $2; exit}' "$CONFIG")"
if ! is_valid_pin "$pin"; then
  while true; do
    random_number="$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')"
    pin="$(printf '%08d' "$((random_number % 100000000))")"
    is_valid_pin "$pin" && break
  done

  config_tmp="$(mktemp "${TMPDIR:-/tmp}/harbor-homekit-config.XXXXXX")"
  awk -v pin="$pin" '
    /^[[:space:]]+pin:/ {
      match($0, /^[[:space:]]*/)
      indent = substr($0, 1, RLENGTH)
      print indent "pin: " pin "        # unique PIN generated during setup"
      next
    }
    { print }
  ' "$CONFIG" > "$config_tmp"
  mv "$config_tmp" "$CONFIG"
fi

chmod 600 "$CONFIG"
printf 'HomeKit setup code: %s-%s-%s\n' "${pin:0:3}" "${pin:3:2}" "${pin:5:3}"
echo "Keep this code private. Running this script again preserves it."
