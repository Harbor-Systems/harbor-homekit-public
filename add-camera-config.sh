#!/usr/bin/env bash
# Add one camera to an existing Harbor go2rtc/HomeKit configuration.
set -euo pipefail

CONFIG_PATH="${1:-}"
CAMERA_SERIAL="${2:-}"
HOMEKIT_PIN="${3:-}"

if [ -z "$CONFIG_PATH" ] || [ ! -f "$CONFIG_PATH" ] ||
   ! printf '%s\n' "$CAMERA_SERIAL" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{2,63}$' ||
   ! printf '%s\n' "$HOMEKIT_PIN" | grep -Eq '^[0-9]{8}$'; then
  echo "Usage: $0 path/to/go2rtc.yaml CAMERA_SERIAL HOMEKIT_PIN" >&2
  exit 1
fi

if grep -Fq "  \"$CAMERA_SERIAL\":" "$CONFIG_PATH"; then
  echo "Camera $CAMERA_SERIAL is already configured."
  exit 0
fi
if ! grep -Eq '^streams:[[:space:]]*$' "$CONFIG_PATH" ||
   ! grep -Eq '^homekit:[[:space:]]*$' "$CONFIG_PATH"; then
  echo "Configuration must contain top-level streams and homekit mappings." >&2
  exit 1
fi

updated="$(mktemp "${CONFIG_PATH}.camera.XXXXXX")"
cleanup() { rm -f "$updated"; }
trap cleanup EXIT

LC_ALL=C awk -v serial="$CAMERA_SERIAL" -v pin="$HOMEKIT_PIN" '
  function print_stream() {
    print "  \"" serial "\":"
    print "    - ffmpeg:" serial "#video=h264#audio=opus#raw=-vf scale=-2:720,setpts=(RTCTIME-RTCSTART)/(TB*1000000) -bsf:v dump_extra=freq=keyframe -x264-params sliced-threads=0 -ar 16000 -ac 1 -b:a 24k"
    print ""
  }
  function print_homekit() {
    print "  \"" serial "\":"
    print "    pin: " pin "        # shared bridge PIN generated during installation"
    print "    name: Harbor Camera " serial
    added_homekit=1
  }
  /^streams:[[:space:]]*$/ {
    in_streams=1
    print
    next
  }
  in_streams && /^[^[:space:]#]/ && !added_stream {
    print_stream()
    added_stream=1
    in_streams=0
  }
  /^homekit:[[:space:]]*$/ {
    in_homekit=1
    print
    next
  }
  in_homekit && /^[^[:space:]#]/ && !added_homekit {
    print_homekit()
    print ""
    in_homekit=0
  }
  { print }
  END {
    if (in_streams && !added_stream) {
      print_stream()
    }
    if (!added_homekit) {
      print_homekit()
    }
  }
' "$CONFIG_PATH" > "$updated"

chmod 600 "$updated"
mv "$updated" "$CONFIG_PATH"
trap - EXIT
echo "Configured additional Harbor camera: $CAMERA_SERIAL"
