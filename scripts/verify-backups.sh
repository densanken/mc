#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
if [ -z "${WORLD_BACKUP_DIR:-}" ] || [ -z "${COREPROTECT_BACKUP_DIR:-}" ]; then
  backup_root="$("$root_dir/scripts/backup-root.sh")"
fi
world_dir="${WORLD_BACKUP_DIR:-$backup_root/world}"
coreprotect_dir="${COREPROTECT_BACKUP_DIR:-$backup_root/coreprotect}"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "FAIL: required command not found: $1" >&2
    exit 2
  fi
}
need gzip
need tar
need sqlite3
need cp
need cmp

temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/mc-backup-verify.XXXXXX")"
temporary_db="$temporary_dir/coreprotect.db"
temporary_level="$temporary_dir/level.dat"
trap 'rm -rf "$temporary_dir"' EXIT

failures=0
shopt -s nullglob
world_archives=("$world_dir"/minecraft-*.tar.gz)
coreprotect_archives=("$coreprotect_dir"/coreprotect-*.db.gz)

if [ "${#world_archives[@]}" -eq 0 ]; then
  echo "FAIL: world backup archive not found"
  failures=$((failures + 1))
fi
if [ "${#coreprotect_archives[@]}" -eq 0 ]; then
  echo "FAIL: CoreProtect backup archive not found"
  failures=$((failures + 1))
fi

# Bash 3.2 では set -u と空配列を組み合わせると通常の "${array[@]}" が失敗する
# shellcheck disable=SC1083
for archive in ${world_archives[@]+"${world_archives[@]}"}; do
  archive_listing=""
  archive_metadata=""
  if [ -L "$archive" ] || [ ! -f "$archive" ]; then
    echo "FAIL: world archive is not a regular file: $archive"
    failures=$((failures + 1))
    continue
  fi
  snapshot="$temporary_dir/world.tar.gz"
  if ! cp "$archive" "$snapshot" ||
      ! gzip -t "$snapshot" ||
      ! archive_listing="$(tar -tzf "$snapshot")" ||
      ! archive_metadata="$(tar -tvzf "$snapshot")"; then
    echo "FAIL: invalid world archive: $archive"
    failures=$((failures + 1))
    continue
  fi
  if awk '
    {
      name = $0
      while (sub(/^\.\//, "", name)) {}
      if (++seen[name] > 1) duplicate = 1
    }
    END { exit !duplicate }
  ' <<<"$archive_listing"; then
    echo "FAIL: duplicate path is present in world archive: $archive"
    failures=$((failures + 1))
    continue
  fi
  if grep -Eq '(^|/)\.\.(/|$)|^/' <<<"$archive_listing"; then
    echo "FAIL: unsafe path is present in world archive: $archive"
    failures=$((failures + 1))
    continue
  fi
  if awk '$1 !~ /^[-d]/ { unsafe = 1 } END { exit !unsafe }' \
      <<<"$archive_metadata"; then
    echo "FAIL: non-file entry is present in world archive: $archive"
    failures=$((failures + 1))
    continue
  fi
  level_member="$(awk '
    {
      original = $0
      name = $0
      while (sub(/^\.\//, "", name)) {}
      if (name == "world/level.dat") print original
    }
  ' <<<"$archive_listing")"
  if [ -z "$level_member" ] || ! awk '
    {
      name = $NF
      while (sub(/^\.\//, "", name)) {}
      if ($1 ~ /^-/ && name == "world/level.dat") found = 1
    }
    END { exit !found }
  ' <<<"$archive_metadata"; then
    echo "FAIL: regular world/level.dat is missing from world archive: $archive"
    failures=$((failures + 1))
    continue
  fi
  if ! tar -xOzf "$snapshot" "$level_member" > "$temporary_level" ||
      [ ! -s "$temporary_level" ] || ! gzip -t "$temporary_level"; then
    echo "FAIL: world/level.dat is empty or invalid: $archive"
    failures=$((failures + 1))
    continue
  fi
  if grep -Eq '(^|/)(server\.properties|\.rcon-cli\.(env|yaml)|plugins/DiscordSRV/([^/]*config\.yml|\.token)|plugins/CoreProtect/database\.db[^/]*)$' \
      <<<"$archive_listing"; then
    echo "FAIL: secret or live database is present in world archive: $archive"
    failures=$((failures + 1))
    continue
  fi
  if [ -L "$archive" ] || [ ! -f "$archive" ] || ! cmp -s "$archive" "$snapshot"; then
    echo "FAIL: world archive changed during verification: $archive"
    failures=$((failures + 1))
    continue
  fi
  echo "OK: world archive: $(basename "$archive")"
done

# shellcheck disable=SC1083
for archive in ${coreprotect_archives[@]+"${coreprotect_archives[@]}"}; do
  if [ -L "$archive" ] || [ ! -f "$archive" ]; then
    echo "FAIL: CoreProtect archive is not a regular file: $archive"
    failures=$((failures + 1))
    continue
  fi
  snapshot="$temporary_dir/coreprotect.db.gz"
  if ! cp "$archive" "$snapshot" ||
      ! gzip -t "$snapshot" || ! gzip -dc "$snapshot" > "$temporary_db"; then
    echo "FAIL: invalid CoreProtect archive: $archive"
    failures=$((failures + 1))
    continue
  fi
  if [ "$(sqlite3 "$temporary_db" 'PRAGMA integrity_check;')" != "ok" ]; then
    echo "FAIL: CoreProtect SQLite integrity check failed: $archive"
    failures=$((failures + 1))
    continue
  fi
  user_table_count="$(sqlite3 "$temporary_db" \
    "SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';")"
  if [ "$user_table_count" -lt 1 ]; then
    echo "FAIL: CoreProtect SQLite schema is missing: $archive"
    failures=$((failures + 1))
    continue
  fi
  if [ -L "$archive" ] || [ ! -f "$archive" ] || ! cmp -s "$archive" "$snapshot"; then
    echo "FAIL: CoreProtect archive changed during verification: $archive"
    failures=$((failures + 1))
    continue
  fi
  echo "OK: CoreProtect archive: $(basename "$archive")"
done

# shellcheck disable=SC1083
for world_archive in ${world_archives[@]+"${world_archives[@]}"}; do
  world_name="${world_archive##*/}"
  if [[ ! "$world_name" =~ ^minecraft-([0-9]{8}-[0-9]{6})(-[0-9]+)?\.tar\.gz$ ]]; then
    echo "FAIL: CoreProtect との対応を検査できない world archive: $world_archive"
    failures=$((failures + 1))
    continue
  fi
  world_timestamp="${BASH_REMATCH[1]}"
  matching_coreprotect=""
  # shellcheck disable=SC1083
  for coreprotect_archive in ${coreprotect_archives[@]+"${coreprotect_archives[@]}"}; do
    coreprotect_name="${coreprotect_archive##*/}"
    if [[ "$coreprotect_name" =~ ^coreprotect-([0-9]{8}-[0-9]{6})(-[0-9]+)?\.db\.gz$ ]]; then
      coreprotect_timestamp="${BASH_REMATCH[1]}"
      if [[ "$coreprotect_timestamp" < "$world_timestamp" ]]; then
        matching_coreprotect="$coreprotect_archive"
        break
      fi
    fi
  done
  if [ -z "$matching_coreprotect" ]; then
    echo "FAIL: world より前の CoreProtect archive がありません: $world_archive"
    failures=$((failures + 1))
  fi
done

if [ "$failures" -gt 0 ]; then
  echo "FAIL: $failures backup verification failure(s)"
  exit 1
fi
echo "OK: all backup archives passed stream and exclusion checks"
