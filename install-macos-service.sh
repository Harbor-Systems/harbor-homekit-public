#!/usr/bin/env bash
# Install Harbor HomeKit as a per-user macOS LaunchAgent.
set -euo pipefail

cd "$(dirname "$0")"

LABEL="co.harbor.homekit"
INSTALL_DIR="$HOME/Library/Application Support/Harbor HomeKit"
LOG_DIR="$HOME/Library/Logs/Harbor HomeKit"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
CONFIG_SOURCE="${1:-./go2rtc.yaml}"
DOMAIN="gui/$(id -u)"

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
  echo "Usage: $0 [path/to/go2rtc.yaml]" >&2
  exit 1
fi

if grep -Ev '^[[:space:]]*#' "$CONFIG_SOURCE" | grep -q 'CAMERA_SERIAL'; then
  echo "Configure the camera serial in $CONFIG_SOURCE before installing." >&2
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

if [ "$config_base" != "$INSTALL_DIR/go2rtc.yaml" ]; then
  ditto "$config_base" "$INSTALL_DIR/go2rtc.yaml"
fi
sed -i '' -E "s/^([[:space:]]+pin:).*/\\1 $homekit_pin        # unique PIN generated during installation/" "$INSTALL_DIR/go2rtc.yaml"
written_pin="$(read_pin "$INSTALL_DIR/go2rtc.yaml")"
if ! is_valid_pin "$written_pin" || [ "$written_pin" != "$homekit_pin" ]; then
  echo "HomeKit pin setting could not be written to $INSTALL_DIR/go2rtc.yaml" >&2
  exit 1
fi
chmod 600 "$INSTALL_DIR/go2rtc.yaml"
ditto ./run-native.sh "$INSTALL_DIR/run-native.sh"
ditto ./generate-homekit-pin.sh "$INSTALL_DIR/generate-homekit-pin.sh"
ditto ./scripts/versions.env "$INSTALL_DIR/scripts/versions.env"
chmod 700 "$INSTALL_DIR/run-native.sh"
chmod 700 "$INSTALL_DIR/generate-homekit-pin.sh"
chmod 600 "$INSTALL_DIR/scripts/versions.env"

# Reuse an already-downloaded binary when present. Otherwise run-native.sh will
# download the configured/latest release on its first launch.
if [ -x ./go2rtc ]; then
  ditto ./go2rtc "$INSTALL_DIR/go2rtc"
  chmod 700 "$INSTALL_DIR/go2rtc"
fi

plutil -create xml1 "$PLIST"
plutil -insert Label -string "$LABEL" "$PLIST"
plutil -insert ProgramArguments -json '["/bin/bash"]' "$PLIST"
plutil -insert ProgramArguments.1 -string "$INSTALL_DIR/run-native.sh" "$PLIST"
plutil -insert WorkingDirectory -string "$INSTALL_DIR" "$PLIST"
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
log_stamp="$(date +%Y%m%d-%H%M%S)"
for log_file in "$LOG_DIR/go2rtc.log" "$LOG_DIR/go2rtc.error.log"; do
  if [ -s "$log_file" ]; then
    mv "$log_file" "$log_file.$log_stamp"
  fi
done
launchctl bootstrap "$DOMAIN" "$PLIST"

api_ready=false
for _ in {1..30}; do
  if curl -fsS --max-time 2 http://127.0.0.1:1984/ >/dev/null; then
    api_ready=true
    break
  fi
  sleep 1
done

if [ "$api_ready" = true ]; then
  echo "Harbor HomeKit is running and will start automatically at login."
else
  echo "The service was installed, but go2rtc is not responding on port 1984." >&2
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
formatted_pin="${homekit_pin:0:3}-${homekit_pin:3:2}-${homekit_pin:5:3}"
echo
echo "HomeKit setup code: $formatted_pin"
echo "Keep this code private. It is preserved across service reinstalls."
echo "Status: launchctl print $DOMAIN/$LABEL"
echo "Logs:   $LOG_DIR"
