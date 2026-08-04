#!/usr/bin/env bash
# Remove the Harbor HomeKit LaunchAgent. Configuration is preserved unless
# --purge is given, which also removes the installed bridge and its logs.
# Purging deletes the HomeKit pairing identity: remove the accessory from the
# Apple Home app BEFORE purging, or it lingers there as unreachable.
set -euo pipefail

LABEL="co.harbor.homekit"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
INSTALL_DIR="$HOME/Library/Application Support/Harbor HomeKit"
LOG_DIR="$HOME/Library/Logs/Harbor HomeKit"
PURGE=false

case "${1:-}" in
  --purge) PURGE=true ;;
  "") ;;
  *)
    echo "Usage: $0 [--purge]" >&2
    exit 1
    ;;
esac

launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
if [ -e "$PLIST" ]; then
  mv "$PLIST" "$HOME/.Trash/$LABEL.plist"
fi

echo "Harbor HomeKit autostart was removed."
if [ "$PURGE" = true ]; then
  rm -rf "$INSTALL_DIR" "$LOG_DIR"
  echo "The bridge, its configuration, and logs were deleted."
  echo "The HomeKit pairing is gone; a reinstall creates a new setup code."
else
  echo "The configuration remains in: $INSTALL_DIR"
fi
