#!/usr/bin/env bash
# Package the Harbor HomeKit Bridge app as a drag-to-Applications disk image
# with the branded background, pinned icon layout, and hidden window chrome.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
app="${1:-$root/dist/Harbor HomeKit Bridge.app}"
output="${2:-$root/dist/Harbor-HomeKit-Bridge.dmg}"
volume_name="Harbor HomeKit Bridge"

if [ ! -d "$app" ]; then
  echo "Setup app not found: $app" >&2
  echo "Build it first with scripts/build-macos-setup-app.sh" >&2
  exit 1
fi

work="$(mktemp -d)"
device=""
cleanup() {
  if [ -n "$device" ]; then
    hdiutil detach "$device" >/dev/null 2>&1 || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

# A volume with the same name would make the Finder layout script ambiguous.
if [ -d "/Volumes/$volume_name" ]; then
  hdiutil detach "/Volumes/$volume_name" >/dev/null
fi

staging="$work/staging"
mkdir -p "$staging/.background"
ditto "$app" "$staging/Harbor HomeKit Bridge.app"
ln -s /Applications "$staging/Applications"
swift "$root/macos/RenderDMGBackground.swift" \
  "$root/macos/HarborLogo.png" "$staging/.background/background.png"

rw_image="$work/rw.dmg"
hdiutil create -volname "$volume_name" -srcfolder "$staging" \
  -fs HFS+ -format UDRW -ov "$rw_image" >/dev/null
device="$(hdiutil attach -readwrite -noverify -noautoopen "$rw_image" \
  | awk '/^\/dev\// {print $1; exit}')"
if [ -z "$device" ] || [ ! -d "/Volumes/$volume_name" ]; then
  echo "Could not mount the writable disk image." >&2
  exit 1
fi

# Window geometry and icon positions must match RenderDMGBackground.swift.
layout_volume() {
  osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$volume_name"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 800, 520}
    set view_options to the icon view options of container window
    set arrangement of view_options to not arranged
    set icon size of view_options to 128
    set text size of view_options to 13
    set background picture of view_options to file ".background:background.png"
    set position of item "Harbor HomeKit Bridge.app" of container window to {150, 190}
    set position of item "Applications" of container window to {450, 190}
    -- Keep support files out of the layout for people who show hidden files.
    repeat with hidden_name in {".background", ".fseventsd", ".DS_Store", ".Trashes"}
      try
        set position of item hidden_name of container window to {150, 700}
      end try
    end repeat
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
}

# Finder automation can be briefly unavailable on fresh CI sessions.
layout_done=false
for _ in 1 2 3; do
  if layout_volume; then
    layout_done=true
    break
  fi
  sleep 3
done
if [ "$layout_done" != true ]; then
  echo "Finder could not apply the disk image layout." >&2
  exit 1
fi

sync
hdiutil detach "$device" >/dev/null
device=""
hdiutil convert "$rw_image" -format UDZO -imagekey zlib-level=9 \
  -ov -o "$output" >/dev/null
echo "Created: $output"
