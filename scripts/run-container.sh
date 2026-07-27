#!/bin/sh
set -eu

config="/config/go2rtc.yaml"
token_file="/harbor/whip-token"

if ! grep -Fq 'listen: "127.0.0.1:1985"' "$config" ||
   ! grep -Fq 'listen: "127.0.0.1:8554"' "$config" ||
   ! grep -Fq 'allow_paths: [/api/streams, /api/webrtc]' "$config" ||
   ! grep -Fq 'allow_paths: [ffmpeg]' "$config"; then
  echo "$config does not contain Harbor's required security settings." >&2
  exit 1
fi

stream_name="$(
  awk '
    /^streams:/ { in_streams=1; next }
    in_streams && /^[^[:space:]#]/ { exit }
    in_streams && /^[[:space:]]+"[^"]+":/ {
      line=$0
      sub(/^[[:space:]]+"/, "", line)
      sub(/":.*/, "", line)
      print line
      exit
    }
  ' "$config"
)"
if [ -z "$stream_name" ] || [ "$stream_name" = "CAMERA_SERIAL" ]; then
  echo "Configure the camera serial in $config before starting." >&2
  exit 1
fi

mkdir -p /harbor
if [ ! -f "$token_file" ]; then
  umask 077
  od -An -N32 -tx1 /dev/urandom | tr -d '[:space:]' > "$token_file"
fi
chmod 600 "$token_file"

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

go2rtc -config "$config" &
go2rtc_pid="$!"
HARBOR_WHIP_TOKEN_FILE="$token_file" \
HARBOR_WHIP_STREAM="$stream_name" \
HARBOR_GO2RTC_URL="http://127.0.0.1:1985" \
  harbor-whip-gateway &
gateway_pid="$!"

while kill -0 "$go2rtc_pid" >/dev/null 2>&1 && \
      kill -0 "$gateway_pid" >/dev/null 2>&1; do
  sleep 2
done
echo "Harbor HomeKit stopped because a required process exited." >&2
exit 1
