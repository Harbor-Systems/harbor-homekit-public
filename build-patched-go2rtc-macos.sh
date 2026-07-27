#!/usr/bin/env bash
# Build the pinned go2rtc release with the macOS mDNS fallback.
set -euo pipefail

cd "$(dirname "$0")"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "This build helper is for macOS only." >&2
  exit 1
fi

if ! command -v go >/dev/null 2>&1; then
  echo "Go is required. Install it with: brew install go" >&2
  exit 1
fi

"$PWD/scripts/build-go2rtc.sh" "$(go env GOOS)" "$(go env GOARCH)" "$PWD/go2rtc"
echo "Built: $PWD/go2rtc"
./go2rtc -version
echo "Run ./install-macos-service.sh to install and supervise this binary."
