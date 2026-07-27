#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

cat > "$fixture/flock" <<'RUBY'
#!/usr/bin/env ruby
exit 2 unless ARGV.length == 2 && ARGV[0] == "-n"
descriptor = File.new(Integer(ARGV[1]), autoclose: false)
exit(descriptor.flock(File::LOCK_EX | File::LOCK_NB) ? 0 : 1)
RUBY
chmod 0755 "$fixture/flock"
export FLOCK_BIN="$fixture/flock"
export COREPROTECT_BACKUP_LOCK_PATH="$fixture/coreprotect-backup.lock"

db="$fixture/database.db"
backup_dir="$fixture/backups"
sqlite3 "$db" 'CREATE TABLE test (id INTEGER PRIMARY KEY, value TEXT); INSERT INTO test(value) VALUES ("ok");'

output="$(KEEP_GENERATIONS=2 "$root_dir/scripts/coreprotect-backup-db.sh" "$db" "$backup_dir")"
gzip -t "$output"
gzip -dc "$output" > "$fixture/restored.db"
integrity="$(sqlite3 "$fixture/restored.db" 'PRAGMA integrity_check;')"
if [ "$integrity" != "ok" ]; then
  echo "FAIL: restored CoreProtect fixture is invalid" >&2
  exit 1
fi

lock_ready="$fixture/flock-ready"
lock_release="$fixture/flock-release"
(
  exec 8>>"$COREPROTECT_BACKUP_LOCK_PATH"
  "$FLOCK_BIN" -n 8
  touch "$lock_ready"
  while [ ! -e "$lock_release" ]; do
    sleep 0.05
  done
) &
lock_pid=$!
for _ in $(seq 1 100); do
  [ ! -e "$lock_ready" ] || break
  sleep 0.05
done
if [ ! -e "$lock_ready" ]; then
  echo "FAIL: test could not acquire the CoreProtect backup lock" >&2
  kill "$lock_pid" 2>/dev/null || true
  wait "$lock_pid" 2>/dev/null || true
  exit 1
fi

if "$root_dir/scripts/coreprotect-backup-db.sh" "$db" "$backup_dir" >/dev/null 2>&1; then
  echo "FAIL: concurrent CoreProtect backup was accepted" >&2
  exit 1
fi

touch "$lock_release"
wait "$lock_pid"

signal_bin="$fixture/bin-signal"
signal_ready="$fixture/signal-ready"
mkdir -p "$signal_bin"
cat > "$signal_bin/ls" <<'EOF'
#!/usr/bin/env sh
: > "$SIGNAL_READY"
sleep 1
exec /bin/ls "$@"
EOF
chmod 0755 "$signal_bin/ls"
SIGNAL_READY="$signal_ready" PATH="$signal_bin:$PATH" KEEP_GENERATIONS=1 \
  "$root_dir/scripts/coreprotect-backup-db.sh" "$db" "$backup_dir" \
  >"$fixture/signal-output" 2>&1 &
signal_pid=$!
for _ in $(seq 1 100); do
  [ ! -e "$signal_ready" ] || break
  sleep 0.05
done
if [ ! -e "$signal_ready" ]; then
  echo "FAIL: signal fixture did not reach backup pruning" >&2
  kill "$signal_pid" 2>/dev/null || true
  wait "$signal_pid" 2>/dev/null || true
  exit 1
fi
kill -TERM "$signal_pid"
signal_status=0
wait "$signal_pid" || signal_status=$?
if [ "$signal_status" -ne 143 ]; then
  echo "FAIL: TERM returned unexpected status: $signal_status" >&2
  exit 1
fi
if [ ! -f "$output" ]; then
  echo "FAIL: TERM allowed CoreProtect backup pruning to continue" >&2
  exit 1
fi

victim="$fixture/lock-victim"
printf 'preserve lock target\n' > "$victim"
rm -f "$COREPROTECT_BACKUP_LOCK_PATH"
ln -s "$victim" "$COREPROTECT_BACKUP_LOCK_PATH"
if "$root_dir/scripts/coreprotect-backup-db.sh" "$db" "$backup_dir" >/dev/null 2>&1; then
  echo "FAIL: symlink CoreProtect lock was accepted" >&2
  exit 1
fi
if [ "$(cat "$victim")" != 'preserve lock target' ]; then
  echo "FAIL: symlink CoreProtect lock truncated its target" >&2
  exit 1
fi
rm "$COREPROTECT_BACKUP_LOCK_PATH"

future_dir="$fixture/future-retention"
mkdir -p "$future_dir"
printf 'invalid future backup\n' > "$future_dir/coreprotect-future.db.gz"
touch -t 209901010000 "$future_dir/coreprotect-future.db.gz"
if KEEP_GENERATIONS=1 "$root_dir/scripts/coreprotect-backup-db.sh" \
    "$db" "$future_dir" >/dev/null 2>&1; then
  echo "FAIL: retention accepted a future or corrupt backup" >&2
  exit 1
fi
if ! find "$future_dir" -type f -name 'coreprotect-*.db.gz' \
    ! -name 'coreprotect-future.db.gz' -print -quit | grep -q .; then
  echo "FAIL: retention pruned the newly created valid backup" >&2
  exit 1
fi

paired_dir="$fixture/paired-retention"
paired_world_dir="$fixture/paired-world"
mkdir -p "$paired_dir" "$paired_world_dir"
cp "$output" "$paired_dir/coreprotect-20260101-010000.db.gz"
cp "$output" "$paired_dir/coreprotect-20260101-010000-1.db.gz"
cp "$output" "$paired_dir/coreprotect-20260101-010000-2.db.gz"
cp "$output" "$paired_dir/coreprotect-20260101-020000.db.gz"
cp "$output" "$paired_dir/coreprotect-20260101-030000.db.gz"
touch -t 202601010100 "$paired_dir/coreprotect-20260101-010000.db.gz"
touch -t 202601010101 "$paired_dir/coreprotect-20260101-010000-1.db.gz"
touch -t 202601010102 "$paired_dir/coreprotect-20260101-010000-2.db.gz"
touch -t 202601010200 "$paired_dir/coreprotect-20260101-020000.db.gz"
touch -t 202601010300 "$paired_dir/coreprotect-20260101-030000.db.gz"
: > "$paired_world_dir/minecraft-20260101-020000.tar.gz"
WORLD_BACKUP_DIR="$paired_world_dir" KEEP_GENERATIONS=1 \
  "$root_dir/scripts/coreprotect-backup-db.sh" "$db" "$paired_dir" >/dev/null
if [ ! -f "$paired_dir/coreprotect-20260101-010000-2.db.gz" ]; then
  echo "FAIL: retention pruned the CoreProtect anchor for a retained world" >&2
  exit 1
fi
if [ -e "$paired_dir/coreprotect-20260101-010000.db.gz" ] ||
    [ -e "$paired_dir/coreprotect-20260101-010000-1.db.gz" ]; then
  echo "FAIL: retention kept an older same-second CoreProtect backup" >&2
  exit 1
fi
if [ -e "$paired_dir/coreprotect-20260101-020000.db.gz" ] ||
    [ -e "$paired_dir/coreprotect-20260101-030000.db.gz" ]; then
  echo "FAIL: retention kept a same-time or newer unpaired CoreProtect backup" >&2
  exit 1
fi

: > "$paired_world_dir/minecraft-manual.tar.gz"
invalid_world_log="$fixture/invalid-world.log"
if ! WORLD_BACKUP_DIR="$paired_world_dir" KEEP_GENERATIONS=1 \
    "$root_dir/scripts/coreprotect-backup-db.sh" "$db" "$paired_dir" \
    >/dev/null 2>"$invalid_world_log"; then
  echo "FAIL: retention stopped on a world backup without a timestamp" >&2
  exit 1
fi
if ! grep -Fq \
    'WARNING: world バックアップの作成時刻を判定できないため、対応する CoreProtect 世代を追加保持しません:' \
    "$invalid_world_log"; then
  echo "FAIL: retention did not warn about a world backup without a timestamp" >&2
  exit 1
fi
if [ ! -f "$paired_dir/coreprotect-20260101-010000-2.db.gz" ]; then
  echo "FAIL: an invalid world caused retention to prune a valid world anchor" >&2
  exit 1
fi

rm "$paired_world_dir/minecraft-20260101-020000.tar.gz"
if ! WORLD_BACKUP_DIR="$paired_world_dir" KEEP_GENERATIONS=1 \
    "$root_dir/scripts/coreprotect-backup-db.sh" "$db" "$paired_dir" \
    >/dev/null 2>>"$invalid_world_log"; then
  echo "FAIL: retention stopped when only a world without a timestamp remained" >&2
  exit 1
fi
if [ -e "$paired_dir/coreprotect-20260101-010000-2.db.gz" ]; then
  echo "FAIL: a world without a timestamp protected a CoreProtect anchor" >&2
  exit 1
fi
rm "$paired_world_dir/minecraft-manual.tar.gz"

ln -s minecraft-missing.tar.gz \
  "$paired_world_dir/minecraft-20260101-020000.tar.gz"
symlink_world_log="$fixture/symlink-world.log"
if WORLD_BACKUP_DIR="$paired_world_dir" KEEP_GENERATIONS=1 \
    "$root_dir/scripts/coreprotect-backup-db.sh" "$db" "$paired_dir" \
    >/dev/null 2>"$symlink_world_log"; then
  echo "FAIL: retention accepted a symlink world backup" >&2
  exit 1
fi
if ! grep -Fq 'ERROR: world バックアップが通常ファイルではありません:' \
    "$symlink_world_log"; then
  echo "FAIL: retention failed for a reason other than the symlink world backup" >&2
  exit 1
fi
rm "$paired_world_dir/minecraft-20260101-020000.tar.gz"

publish_dir="$fixture/publish-race"
publish_bin="$fixture/bin-publish-race"
publish_marker="$fixture/publish-race-triggered"
mkdir -p "$publish_dir" "$publish_bin"
cat > "$publish_bin/ln" <<'EOF'
#!/usr/bin/env sh
if [ ! -e "$PUBLISH_MARKER" ]; then
  : > "$PUBLISH_MARKER"
  printf 'concurrent archive\n' > "$2"
  exit 1
fi
exec /bin/ln "$@"
EOF
chmod 0755 "$publish_bin/ln"
published_output="$(PATH="$publish_bin:$PATH" PUBLISH_MARKER="$publish_marker" \
  "$root_dir/scripts/coreprotect-backup-db.sh" "$db" "$publish_dir")"
concurrent_output="$(find "$publish_dir" -type f -name 'coreprotect-*.db.gz' \
  ! -path "$published_output" -print -quit)"
if [ "$(cat "$concurrent_output")" != 'concurrent archive' ] ||
    [ ! -f "$published_output" ]; then
  echo "FAIL: no-clobber publication did not preserve the concurrent archive" >&2
  exit 1
fi

if FLOCK_BIN="$fixture/missing-flock" \
    "$root_dir/scripts/coreprotect-backup-db.sh" "$db" "$fixture/no-flock" \
    >/dev/null 2>&1; then
  echo "FAIL: CoreProtect backup accepted a missing flock command" >&2
  exit 1
fi

assert_failed_cleanly() {
  local case_name="$1"
  local failure_status="$2"
  local failure_dir="$fixture/failure-$case_name"
  local fake_bin="$fixture/bin-$case_name"
  mkdir -p "$failure_dir" "$fake_bin"
  printf '#!/bin/sh\nexit %s\n' "$failure_status" > "$fake_bin/$case_name"
  chmod 0755 "$fake_bin/$case_name"

  if PATH="$fake_bin:$PATH" "$root_dir/scripts/coreprotect-backup-db.sh" \
      "$db" "$failure_dir" >/dev/null 2>&1; then
    echo "FAIL: $case_name failure was accepted" >&2
    exit 1
  fi
  if find "$failure_dir" -type f | grep -q .; then
    echo "FAIL: $case_name failure left a temporary or final archive" >&2
    exit 1
  fi
}

# exit 28 simulates allocation failure such as ENOSPC.
assert_failed_cleanly mktemp 28
assert_failed_cleanly sqlite3 42
assert_failed_cleanly gzip 43

echo "OK: CoreProtect backup fixtures passed"
