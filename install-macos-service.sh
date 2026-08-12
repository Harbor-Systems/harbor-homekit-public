#!/usr/bin/env bash
# Install Harbor HomeKit as a per-user macOS LaunchAgent.
set -euo pipefail

cd "$(dirname "$0")"

LABEL="co.harbor.homekit"
APP_NAME="Harbor HomeKit Bridge"
APP_BUNDLE_ID="co.harbor.homekit.bridge"
INSTALL_DIR="$HOME/Library/Application Support/Harbor HomeKit"
APP_DIR="$INSTALL_DIR/$APP_NAME.app"
LOG_DIR="$HOME/Library/Logs/Harbor HomeKit"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
CONFIG_SOURCE="./go2rtc.yaml"
CONFIG_SOURCE_SET=false
CAMERA_SERIAL=""
DOMAIN="gui/$(id -u)"

usage() {
  cat >&2 <<EOF
Usage: $0 [--camera-serial SERIAL] [path/to/go2rtc.yaml]

If the config still contains CAMERA_SERIAL, the installer prompts for it.
Use --camera-serial for noninteractive installation.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --camera-serial)
      if [ "$#" -lt 2 ]; then
        usage
        exit 1
      fi
      CAMERA_SERIAL="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
    *)
      if [ "$CONFIG_SOURCE_SET" = true ]; then
        echo "Only one config path may be provided." >&2
        usage
        exit 1
      fi
      CONFIG_SOURCE="$1"
      CONFIG_SOURCE_SET=true
      shift
      ;;
  esac
done

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

generate_pin() {
  while true; do
    random_number="$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')"
    candidate="$(printf '%08d' "$((random_number % 100000000))")"
    if is_valid_pin "$candidate"; then
      printf '%s\n' "$candidate"
      return
    fi
  done
}

read_pin() {
  awk '/^[[:space:]]+pin:/{gsub(/[^0-9]/, "", $2); print $2; exit}' "$1"
}

if [ "$(uname -s)" != "Darwin" ]; then
  echo "This installer is for macOS only." >&2
  exit 1
fi

if [ ! -f "$CONFIG_SOURCE" ]; then
  echo "Config not found: $CONFIG_SOURCE" >&2
  usage
  exit 1
fi

source_pin="$(read_pin "$CONFIG_SOURCE")"
installed_pin=""
if [ -f "$INSTALL_DIR/go2rtc.yaml" ]; then
  installed_pin="$(read_pin "$INSTALL_DIR/go2rtc.yaml")"
fi

if is_valid_pin "$source_pin"; then
  homekit_pin="$source_pin"
elif is_valid_pin "$installed_pin"; then
  # Preserve the pairing identity across upgrades and reinstalls.
  homekit_pin="$installed_pin"
else
  homekit_pin="$(generate_pin)"
fi

mkdir -p "$INSTALL_DIR" "$LOG_DIR" "$HOME/Library/LaunchAgents"
mkdir -p "$INSTALL_DIR/scripts"
chmod 700 "$INSTALL_DIR" "$LOG_DIR"
chmod 700 "$INSTALL_DIR/scripts"

# go2rtc writes paired Home controller records back into its active config.
# Once those records exist, keep the installed config as the upgrade base so a
# reinstall cannot silently unpair the customer's Home. Before first pairing,
# use the caller's source config normally.
config_base="$CONFIG_SOURCE"
if [ -f "$INSTALL_DIR/go2rtc.yaml" ] && \
    grep -Eq '^[[:space:]]+pairings:' "$INSTALL_DIR/go2rtc.yaml"; then
  config_base="$INSTALL_DIR/go2rtc.yaml"
fi

# Render the downloaded template into a temporary config. This keeps the
# customer's source checkout unchanged and avoids prompting during upgrades of
# an already-paired bridge.
rendered_config=""
cleanup_rendered_config() {
  if [ -n "$rendered_config" ]; then
    rm -f "$rendered_config"
  fi
}
trap cleanup_rendered_config EXIT
if grep -Ev '^[[:space:]]*#' "$config_base" | grep -q 'CAMERA_SERIAL'; then
  rendered_config="$(mktemp "${TMPDIR:-/tmp}/harbor-homekit-config.XXXXXX")"
  ditto "$config_base" "$rendered_config"
  ./configure-camera-serial.sh "$rendered_config" "$CAMERA_SERIAL"
  config_base="$rendered_config"
fi

if grep -Ev '^[[:space:]]*#' "$config_base" | grep -q 'CAMERA_SERIAL'; then
  echo "The camera serial could not be configured." >&2
  exit 1
fi

if [ "$config_base" != "$INSTALL_DIR/go2rtc.yaml" ]; then
  ditto "$config_base" "$INSTALL_DIR/go2rtc.yaml"
fi

# Migrate the v0.1.x paired config without replacing the HomeKit records that
# go2rtc wrote into it. Refuse to guess when a customer already has custom
# top-level security/listener blocks.
if ! grep -Fq 'listen: "127.0.0.1:1985"' "$INSTALL_DIR/go2rtc.yaml" ||
   ! grep -Fq 'listen: "127.0.0.1:8554"' "$INSTALL_DIR/go2rtc.yaml" ||
   ! grep -Fq 'allow_paths: [/api/streams, /api/webrtc]' "$INSTALL_DIR/go2rtc.yaml" ||
   ! grep -Fq 'allow_paths: [ffmpeg]' "$INSTALL_DIR/go2rtc.yaml"; then
  if grep -Eq '^(app|api|rtsp|exec):[[:space:]]*$' "$INSTALL_DIR/go2rtc.yaml"; then
    echo "The installed config has custom listener/security settings." >&2
    echo "Back it up, merge the hardened blocks from go2rtc.yaml, and retry." >&2
    exit 1
  fi
  migrated_config="$(mktemp "$INSTALL_DIR/go2rtc.yaml.migrate.XXXXXX")"
  {
    printf '%s\n' \
      'app:' \
      '  modules: [api, rtsp, webrtc, exec, ffmpeg, homekit]' \
      '' \
      'api:' \
      '  listen: "127.0.0.1:1985"' \
      '  allow_paths: [/api/streams, /api/webrtc]' \
      '' \
      'rtsp:' \
      '  listen: "127.0.0.1:8554"' \
      '' \
      'exec:' \
      '  allow_paths: [ffmpeg]' \
      ''
    sed '/^# go2rtc — Harbor camera/,/^# Defaults used/d' "$INSTALL_DIR/go2rtc.yaml"
  } > "$migrated_config"
  chmod 600 "$migrated_config"
  mv "$migrated_config" "$INSTALL_DIR/go2rtc.yaml"
fi
# Migrate pre-v0.4 configs: HomeKit needs the dedicated pairing listener and
# the srtp module, added alongside the existing hardened blocks.
if ! grep -Fq 'homekit_listen:' "$INSTALL_DIR/go2rtc.yaml"; then
  sed -i '' 's/^  modules: \[api, rtsp, webrtc, exec, ffmpeg, homekit\]$/  modules: [api, rtsp, webrtc, exec, ffmpeg, homekit, srtp]/' \
    "$INSTALL_DIR/go2rtc.yaml"
  printf '\n%s\n%s\n' \
    '# Apple Home pairs over this dedicated listener; see repository go2rtc.yaml.' \
    'homekit_listen: ":21063"' >> "$INSTALL_DIR/go2rtc.yaml"
fi
# Migrate configs that predate the strict HomeKit transcode settings. Apple's
# receiver rejects multi-slice frames and expects the negotiated Main 4.0 /
# 720p / 16 kHz mono stream; see repository go2rtc.yaml for the breakdown.
if ! grep -Fq 'sliced-threads=0' "$INSTALL_DIR/go2rtc.yaml"; then
  sed -i '' -E 's|^(    - ffmpeg:[^#]+#video=h264#audio=opus)$|\1#raw=-vf scale=-2:720,setpts=(RTCTIME-RTCSTART)/(TB*1000000) -bsf:v dump_extra=freq=keyframe -x264-params sliced-threads=0 -ar 16000 -ac 1 -b:a 24k|' \
    "$INSTALL_DIR/go2rtc.yaml"
fi
if ! grep -Eq '^ffmpeg:' "$INSTALL_DIR/go2rtc.yaml"; then
  {
    echo ''
    echo '# HomeKit negotiates H264 Main 4.0; override the built-in High 4.1 template.'
    echo 'ffmpeg:'
    echo '  h264: "-c:v libx264 -g 50 -profile:v main -level:v 4.0 -preset:v superfast -tune:v zerolatency -pix_fmt:v yuv420p"'
  } >> "$INSTALL_DIR/go2rtc.yaml"
fi
sed -i '' -E "s/^([[:space:]]+pin:).*/\\1 $homekit_pin        # unique PIN generated during installation/" "$INSTALL_DIR/go2rtc.yaml"
written_pin="$(read_pin "$INSTALL_DIR/go2rtc.yaml")"
if ! is_valid_pin "$written_pin" || [ "$written_pin" != "$homekit_pin" ]; then
  echo "HomeKit pin setting could not be written to $INSTALL_DIR/go2rtc.yaml" >&2
  exit 1
fi

# Subsequent wizard runs add a camera without replacing the existing config,
# pairing database, PIN, or previously configured cameras.
if [ -n "$CAMERA_SERIAL" ]; then
  ./add-camera-config.sh "$INSTALL_DIR/go2rtc.yaml" "$CAMERA_SERIAL" "$homekit_pin"
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
  ' "$INSTALL_DIR/go2rtc.yaml"
)"
if [ -n "$CAMERA_SERIAL" ] &&
   grep -Fq "  \"$CAMERA_SERIAL\":" "$INSTALL_DIR/go2rtc.yaml"; then
  stream_name="$CAMERA_SERIAL"
fi
if [ -z "$stream_name" ]; then
  echo "Could not determine the configured Harbor camera serial." >&2
  exit 1
fi
chmod 600 "$INSTALL_DIR/go2rtc.yaml"
ditto ./run-native.sh "$INSTALL_DIR/run-native.sh"
ditto ./generate-homekit-pin.sh "$INSTALL_DIR/generate-homekit-pin.sh"
ditto ./add-camera-config.sh "$INSTALL_DIR/add-camera-config.sh"
ditto ./scripts/versions.env "$INSTALL_DIR/scripts/versions.env"
chmod 700 "$INSTALL_DIR/run-native.sh"
chmod 700 "$INSTALL_DIR/generate-homekit-pin.sh"
chmod 700 "$INSTALL_DIR/add-camera-config.sh"
chmod 600 "$INSTALL_DIR/scripts/versions.env"

# Reuse an already-downloaded binary when present. Otherwise run-native.sh will
# download the configured/latest release on its first launch.
if [ -x ./go2rtc ]; then
  ditto ./go2rtc "$INSTALL_DIR/go2rtc"
  chmod 700 "$INSTALL_DIR/go2rtc"
fi
if [ -x ./harbor-whip-gateway ]; then
  ditto ./harbor-whip-gateway "$INSTALL_DIR/harbor-whip-gateway"
  chmod 700 "$INSTALL_DIR/harbor-whip-gateway"
fi
if [ -x ./harbor-bridge-launcher ]; then
  ditto ./harbor-bridge-launcher "$INSTALL_DIR/harbor-bridge-launcher"
  chmod 700 "$INSTALL_DIR/harbor-bridge-launcher"
fi

# The launcher must exist before the service starts because it is the app
# bundle's main executable; fetch the pinned release binaries up front.
if [ ! -x "$INSTALL_DIR/harbor-bridge-launcher" ] ||
   [ ! -x "$INSTALL_DIR/go2rtc" ] ||
   [ ! -x "$INSTALL_DIR/harbor-whip-gateway" ]; then
  (cd "$INSTALL_DIR" && HARBOR_DOWNLOAD_ONLY=1 /bin/bash ./run-native.sh)
fi
if [ ! -x "$INSTALL_DIR/harbor-bridge-launcher" ]; then
  echo "This release does not include harbor-bridge-launcher, which macOS" >&2
  echo "needs to grant the bridge Local Network access. Install a newer" >&2
  echo "release, or build it from source: go build ./cmd/bridge-launcher" >&2
  exit 1
fi

# macOS only grants Local Network access to app bundles, so the LaunchAgent
# starts the launcher from inside a branded, signed bundle. The downloaded
# go2rtc/gateway binaries stay outside the bundle: replacing them on upgrade
# must not invalidate the bundle's code signature.
# shellcheck disable=SC1091
bundle_version="$(. ./scripts/versions.env && printf '%s' "${HARBOR_HOMEKIT_RELEASE#v}")"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
ditto "$INSTALL_DIR/harbor-bridge-launcher" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod 755 "$APP_DIR/Contents/MacOS/$APP_NAME"
INFO_PLIST="$APP_DIR/Contents/Info.plist"
plutil -create xml1 "$INFO_PLIST"
plutil -insert CFBundleIdentifier -string "$APP_BUNDLE_ID" "$INFO_PLIST"
plutil -insert CFBundleName -string "$APP_NAME" "$INFO_PLIST"
plutil -insert CFBundleDisplayName -string "$APP_NAME" "$INFO_PLIST"
plutil -insert CFBundleExecutable -string "$APP_NAME" "$INFO_PLIST"
plutil -insert CFBundlePackageType -string APPL "$INFO_PLIST"
plutil -insert CFBundleShortVersionString -string "$bundle_version" "$INFO_PLIST"
plutil -insert CFBundleVersion -string "$bundle_version" "$INFO_PLIST"
plutil -insert LSUIElement -bool true "$INFO_PLIST"
plutil -insert NSLocalNetworkUsageDescription -string \
  "Harbor HomeKit Bridge advertises your camera to Apple Home and streams video to it over your local network." \
  "$INFO_PLIST"
plutil -insert NSBonjourServices -json '["_hap._tcp"]' "$INFO_PLIST"
plutil -lint "$INFO_PLIST"

# Prefer the customer's Developer ID identity when one exists; otherwise an
# ad-hoc signature still gives TCC a stable code identity to attach the
# Local Network grant to (same content signs to the same identity, so
# reinstalls of the same version keep the grant).
signing_identity="$(security find-identity -v -p codesigning 2>/dev/null |
  awk -F'"' '/Developer ID Application/{print $2; exit}')"
if [ -n "$signing_identity" ]; then
  codesign --force --options runtime --timestamp \
    --identifier "$APP_BUNDLE_ID" --sign "$signing_identity" "$APP_DIR"
else
  codesign --force --identifier "$APP_BUNDLE_ID" --sign - "$APP_DIR"
fi
codesign --verify --strict "$APP_DIR"
# Register the bundle so the Local Network pane and prompt show its name.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$APP_DIR" >/dev/null 2>&1 || true

plutil -create xml1 "$PLIST"
plutil -insert Label -string "$LABEL" "$PLIST"
plutil -insert ProgramArguments -json '[]' "$PLIST"
plutil -insert ProgramArguments.0 -string "$APP_DIR/Contents/MacOS/$APP_NAME" "$PLIST"
plutil -insert WorkingDirectory -string "$INSTALL_DIR" "$PLIST"
# Lets Login Items and Local Network attribute the agent to the bundle.
plutil -insert AssociatedBundleIdentifiers -string "$APP_BUNDLE_ID" "$PLIST"
plutil -insert RunAtLoad -bool true "$PLIST"
plutil -insert KeepAlive -bool true "$PLIST"
plutil -insert ProcessType -string Interactive "$PLIST"
plutil -insert ThrottleInterval -integer 10 "$PLIST"
plutil -insert EnvironmentVariables -json '{}' "$PLIST"
plutil -insert EnvironmentVariables.PATH -string "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" "$PLIST"
plutil -insert StandardOutPath -string "$LOG_DIR/go2rtc.log" "$PLIST"
plutil -insert StandardErrorPath -string "$LOG_DIR/go2rtc.error.log" "$PLIST"
chmod 600 "$PLIST"
plutil -lint "$PLIST"

launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
# bootout returns before launchd finishes tearing down a running service;
# bootstrapping while the label still exists fails with an I/O error.
for _ in {1..20}; do
  if ! launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  echo "Could not stop the existing Harbor HomeKit service." >&2
  exit 1
fi
log_stamp="$(date +%Y%m%d-%H%M%S)"
for log_file in "$LOG_DIR/go2rtc.log" "$LOG_DIR/go2rtc.error.log"; do
  if [ -s "$log_file" ]; then
    mv "$log_file" "$log_file.$log_stamp"
  fi
done
# The setup app's Stop Bridge disables the service so it stays stopped across
# logins; bootstrap fails on a disabled service, so installing re-enables it.
launchctl enable "$DOMAIN/$LABEL"
launchctl bootstrap "$DOMAIN" "$PLIST"
# Background Task Management can defer a newly registered agent's RunAtLoad
# spawn past the health check below; force the first launch.
launchctl kickstart "$DOMAIN/$LABEL"

api_ready=false
for _ in {1..30}; do
  gateway_status="$(curl -s --max-time 2 -o /dev/null -w '%{http_code}' \
    -X POST 'http://127.0.0.1:1984/api/webrtc' || true)"
  if curl -fs --max-time 2 http://127.0.0.1:1985/api/streams >/dev/null 2>&1 &&
     [ "$gateway_status" = "401" ]; then
    api_ready=true
    break
  fi
  sleep 1
done

if [ "$api_ready" = true ]; then
  echo "Harbor HomeKit is running and will start automatically at login."
else
  echo "The service was installed, but its local services are not responding." >&2
  echo "Check: $LOG_DIR/go2rtc.error.log" >&2
  exit 1
fi

if grep -q 'no interfaces for listen' "$LOG_DIR/go2rtc.error.log" "$LOG_DIR/go2rtc.log" 2>/dev/null; then
  echo >&2
  echo "HomeKit discovery could not bind its mDNS interface." >&2
  echo "This is a known go2rtc issue on some macOS versions; it is not a" >&2
  echo "Local Network privacy setting on macOS Sonoma." >&2
  echo "Upstream fix: https://github.com/AlexxIT/go2rtc/pull/1283" >&2
  exit 2
fi

echo "HomeKit discovery started without an mDNS interface error."

# macOS Local Network privacy can silently drop the bridge's mDNS multicast.
# Browse briefly and warn when the accessory is not visible.
mdns_browse_log="$(mktemp "${TMPDIR:-/tmp}/harbor-homekit-mdns.XXXXXX")"
dns-sd -B _hap._tcp local. > "$mdns_browse_log" 2>&1 &
mdns_browse_pid=$!
sleep 4
kill "$mdns_browse_pid" >/dev/null 2>&1 || true
if ! sed -n '/Instance Name/,$p' "$mdns_browse_log" | grep -q '_hap._tcp'; then
  echo >&2
  echo "WARNING: no HomeKit accessory is visible on the network yet." >&2
  echo "macOS may still be asking for permission, or may be blocking the" >&2
  echo "bridge's Local Network access. Approve the \"$APP_NAME\" prompt, or" >&2
  echo "open System Settings > Privacy & Security > Local Network and allow" >&2
  echo "\"$APP_NAME\", then rerun this installer." >&2
fi
rm -f "$mdns_browse_log"
# Grouped like the Home app's code-entry field (####-####).
formatted_pin="${homekit_pin:0:4}-${homekit_pin:4:4}"
echo
echo "HomeKit setup code: $formatted_pin"
echo "Keep this code private. It is preserved across service reinstalls."
if [ -f "$INSTALL_DIR/.harbor-whip-token" ]; then
  ingest_token="$(tr -d '[:space:]' < "$INSTALL_DIR/.harbor-whip-token")"
  default_interface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
  bridge_ip=""
  if [ -n "$default_interface" ]; then
    bridge_ip="$(ipconfig getifaddr "$default_interface" 2>/dev/null || true)"
  fi
  echo
  echo "Harbor camera WHIP endpoint:"
  if [ -n "$bridge_ip" ]; then
    echo "http://$bridge_ip:1984/api/webrtc?dst=${stream_name:-CAMERA_SERIAL}&token=$ingest_token"
  else
    echo "Could not determine this Mac's LAN IP." >&2
    echo "Replace BRIDGE_IP in the URL below with this Mac's LAN IP:" >&2
    echo "http://BRIDGE_IP:1984/api/webrtc?dst=${stream_name:-CAMERA_SERIAL}&token=$ingest_token"
  fi
  echo "Treat this URL as a password."
fi
echo "Status: launchctl print $DOMAIN/$LABEL"
echo "Logs:   $LOG_DIR"
