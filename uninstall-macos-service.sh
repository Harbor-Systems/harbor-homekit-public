#!/usr/bin/env bash
# Remove the Harbor HomeKit LaunchAgent. Configuration is preserved.
set -euo pipefail

LABEL="co.harbor.homekit"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
if [ -e "$PLIST" ]; then
  mv "$PLIST" "$HOME/.Trash/$LABEL.plist"
fi

echo "Harbor HomeKit autostart was removed."
echo "The configuration remains in: $HOME/Library/Application Support/Harbor HomeKit"
