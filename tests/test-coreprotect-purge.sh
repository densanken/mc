#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

cat > "$fixture/docker" <<'DOCKER'
#!/usr/bin/env sh
set -eu
count=0
[ ! -f "$PURGE_COUNT_FILE" ] || count="$(cat "$PURGE_COUNT_FILE")"
count=$((count + 1))
printf '%s\n' "$count" > "$PURGE_COUNT_FILE"
[ "$count" -ge "${PURGE_SUCCEEDS_ON:-1}" ]
DOCKER
cat > "$fixture/sleep" <<'SLEEP'
#!/usr/bin/env sh
exit 0
SLEEP
chmod 0755 "$fixture/docker" "$fixture/sleep"

PURGE_COUNT_FILE="$fixture/count" PURGE_SUCCEEDS_ON=3 PATH="$fixture:$PATH" \
COREPROTECT_PURGE_ATTEMPTS=3 COREPROTECT_PURGE_RETRY_SECONDS=1 \
  "$root_dir/scripts/coreprotect-purge-30d.sh" >/dev/null 2>&1
[ "$(cat "$fixture/count")" = 3 ]

rm -f "$fixture/count"
if PURGE_COUNT_FILE="$fixture/count" PURGE_SUCCEEDS_ON=4 PATH="$fixture:$PATH" \
    COREPROTECT_PURGE_ATTEMPTS=3 COREPROTECT_PURGE_RETRY_SECONDS=1 \
    "$root_dir/scripts/coreprotect-purge-30d.sh" >/dev/null 2>&1; then
  echo "FAIL: CoreProtect purge accepted exhausted retries" >&2
  exit 1
fi

for retry_settings in \
  'COREPROTECT_PURGE_ATTEMPTS=00 COREPROTECT_PURGE_RETRY_SECONDS=1' \
  'COREPROTECT_PURGE_ATTEMPTS=1:2 COREPROTECT_PURGE_RETRY_SECONDS=1' \
  'COREPROTECT_PURGE_ATTEMPTS=1 COREPROTECT_PURGE_RETRY_SECONDS=00' \
  'COREPROTECT_PURGE_ATTEMPTS=1 COREPROTECT_PURGE_RETRY_SECONDS=1:2'
do
  read -r attempts retry_seconds <<<"$retry_settings"
  attempts="${attempts#COREPROTECT_PURGE_ATTEMPTS=}"
  retry_seconds="${retry_seconds#COREPROTECT_PURGE_RETRY_SECONDS=}"
  if env PURGE_COUNT_FILE="$fixture/count" PATH="$fixture:$PATH" \
      COREPROTECT_PURGE_ATTEMPTS="$attempts" \
      COREPROTECT_PURGE_RETRY_SECONDS="$retry_seconds" \
      "$root_dir/scripts/coreprotect-purge-30d.sh" \
      >/dev/null 2>&1; then
    echo "FAIL: invalid purge retry settings were accepted: $retry_settings" >&2
    exit 1
  fi
done

echo "OK: CoreProtect purge retry fixtures passed"
