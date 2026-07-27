#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

for script in ./*.sh ./scripts/*.sh ./tests/*.sh; do
  bash -n "$script"
done

if [ "$(grep -o 'CAMERA_SERIAL' go2rtc.yaml | wc -l | tr -d ' ')" -ne 3 ]; then
  echo "go2rtc.yaml must use CAMERA_SERIAL consistently in three places" >&2
  exit 1
fi

if ! grep -q 'listen: "127.0.0.1:1985"' go2rtc.yaml ||
   ! grep -q 'listen: "127.0.0.1:8554"' go2rtc.yaml; then
  echo "go2rtc API and RTSP listeners must remain loopback-only" >&2
  exit 1
fi

if ! grep -Fq 'allow_paths: [/api/streams, /api/webrtc]' go2rtc.yaml ||
   ! grep -Fq 'allow_paths: [ffmpeg]' go2rtc.yaml; then
  echo "go2rtc API and executable allowlists are missing" >&2
  exit 1
fi

if grep -Eq 'alexxit/go2rtc:latest' docker-compose.yml; then
  echo "Docker image must be pinned to a release" >&2
  exit 1
fi

if grep -Eq 'releases/latest|GO2RTC_VERSION:-latest' run-native.sh; then
  echo "Native runner must not download an unpinned latest release" >&2
  exit 1
fi

if ! grep -q 'Project Monitor Inc.' LICENSE; then
  echo "MIT license copyright holder is missing" >&2
  exit 1
fi

./tests/test-pin-generation.sh
echo "Repository tests passed"
