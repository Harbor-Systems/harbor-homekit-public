#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

archive="archive.zip"
printf 'fixture\n' > "$TMP_DIR/$archive"
(
  cd "$TMP_DIR"
  shasum -a 256 -- *.zip > checksums.txt
)

if grep -Fq " ./$archive" "$TMP_DIR/checksums.txt"; then
  echo "Generated checksum manifest must contain archive basenames" >&2
  exit 1
fi

expected_hash="$(shasum -a 256 "$TMP_DIR/$archive" | awk '{print $1}')"
for manifest_name in checksums.txt legacy-checksums.txt; do
  if [ "$manifest_name" = "legacy-checksums.txt" ]; then
    printf '%s  ./%s\n' "$expected_hash" "$archive" > "$TMP_DIR/$manifest_name"
  fi
  selected="$(HARBOR_CHECKSUM_LOOKUP_ONLY=1 \
    "$ROOT_DIR/run-native.sh" "$TMP_DIR/$manifest_name" "$archive")"
  if [ "${selected%% *}" != "$expected_hash" ]; then
    echo "Native runner rejected checksum fixture: $manifest_name" >&2
    exit 1
  fi
done

echo "Checksum manifest tests passed"
