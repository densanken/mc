#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'chmod 0700 "$fixture/storage" 2>/dev/null || true; rm -rf "$fixture"' EXIT

mkdir -p "$fixture/storage"
if BACKUP_STORAGE_DIR="$fixture/storage" \
    "$root_dir/scripts/check-backup-storage.sh" >/dev/null 2>&1; then
  echo "FAIL: backup storage probe accepted a missing sentinel" >&2
  exit 1
fi

printf 'mc-backup-world-v1\n' > "$fixture/storage/.mc-backup-world-v1"
BACKUP_STORAGE_DIR="$fixture/storage" \
  "$root_dir/scripts/check-backup-storage.sh"
if find "$fixture/storage" -name '.write-probe.*' -print -quit | grep -q .; then
  echo "FAIL: backup storage probe left a temporary file" >&2
  exit 1
fi

mkdir -p "$fixture/bin"
printf '#!/usr/bin/env sh\nexit 28\n' > "$fixture/bin/sync"
chmod 0755 "$fixture/bin/sync"
if PATH="$fixture/bin:$PATH" BACKUP_STORAGE_DIR="$fixture/storage" \
    "$root_dir/scripts/check-backup-storage.sh" >/dev/null 2>&1; then
  echo "FAIL: backup storage probe accepted a sync failure" >&2
  exit 1
fi
if find "$fixture/storage" -name '.write-probe.*' -print -quit | grep -q .; then
  echo "FAIL: failed backup storage probe left a temporary file" >&2
  exit 1
fi

echo "OK: backup storage write probe fixtures passed"
