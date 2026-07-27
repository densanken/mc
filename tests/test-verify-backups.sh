#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
real_tar="$(command -v tar)"
real_cp="$(command -v cp)"

mkdir -p "$fixture/world" "$fixture/coreprotect" "$fixture/data/world"
printf 'level nbt fixture\n' | gzip > "$fixture/data/world/level.dat"
tar -czf "$fixture/world/minecraft-20260101-020000.tar.gz" -C "$fixture/data" .
sqlite3 "$fixture/coreprotect-test.db" \
  'CREATE TABLE block_log (id INTEGER PRIMARY KEY, material TEXT); INSERT INTO block_log(material) VALUES ("stone");'
gzip -c "$fixture/coreprotect-test.db" > \
  "$fixture/coreprotect/coreprotect-20260101-010000.db.gz"

WORLD_BACKUP_DIR="$fixture/world" COREPROTECT_BACKUP_DIR="$fixture/coreprotect" \
  "$root_dir/scripts/verify-backups.sh" >/dev/null

cp "$fixture/world/minecraft-20260101-020000.tar.gz" "$fixture/original-safe.tar.gz"
printf 'secret after snapshot\n' > "$fixture/data/server.properties"
tar -czf "$fixture/replacement-unsafe.tar.gz" -C "$fixture/data" .
rm "$fixture/data/server.properties"
mkdir -p "$fixture/swap-bin"
cat > "$fixture/swap-bin/tar" <<'EOF'
#!/usr/bin/env sh
if [ ! -e "$SWAP_MARKER" ]; then
  : > "$SWAP_MARKER"
  "$REAL_CP" "$UNSAFE_ARCHIVE" "$ORIGINAL_ARCHIVE"
fi
exec "$REAL_TAR" "$@"
EOF
chmod 0755 "$fixture/swap-bin/tar"
if PATH="$fixture/swap-bin:$PATH" SWAP_MARKER="$fixture/swap-marker" \
    REAL_CP="$real_cp" REAL_TAR="$real_tar" \
    UNSAFE_ARCHIVE="$fixture/replacement-unsafe.tar.gz" \
    ORIGINAL_ARCHIVE="$fixture/world/minecraft-20260101-020000.tar.gz" \
    WORLD_BACKUP_DIR="$fixture/world" COREPROTECT_BACKUP_DIR="$fixture/coreprotect" \
    "$root_dir/scripts/verify-backups.sh" >/dev/null 2>&1; then
  echo "FAIL: world archive replacement during verification was accepted" >&2
  exit 1
fi
cp "$fixture/original-safe.tar.gz" \
  "$fixture/world/minecraft-20260101-020000.tar.gz"

mkdir -p "$fixture/data/plugins/DiscordSRV"
printf 'secret\n' > "$fixture/data/plugins/DiscordSRV/.token"
tar -czf "$fixture/world/minecraft-20260101-020001.tar.gz" -C "$fixture/data" .
if WORLD_BACKUP_DIR="$fixture/world" COREPROTECT_BACKUP_DIR="$fixture/coreprotect" \
    "$root_dir/scripts/verify-backups.sh" >/dev/null 2>&1; then
  echo "FAIL: world archive containing DiscordSRV .token was accepted" >&2
  exit 1
fi
rm -f "$fixture/world/minecraft-20260101-020001.tar.gz" "$fixture/data/plugins/DiscordSRV/.token"

printf 'BotToken: secret\n' > "$fixture/data/plugins/DiscordSRV/English.config.yml"
tar -czf "$fixture/world/minecraft-20260101-020002.tar.gz" -C "$fixture/data" .
if WORLD_BACKUP_DIR="$fixture/world" COREPROTECT_BACKUP_DIR="$fixture/coreprotect" \
    "$root_dir/scripts/verify-backups.sh" >/dev/null 2>&1; then
  echo "FAIL: world archive containing DiscordSRV YAML was accepted" >&2
  exit 1
fi
rm -f "$fixture/world/minecraft-20260101-020002.tar.gz" \
  "$fixture/data/plugins/DiscordSRV/English.config.yml"

printf 'non-secret runtime settings\n' > "$fixture/data/plugins/DiscordSRV/messages.yml"
tar -czf "$fixture/world/minecraft-20260101-020003.tar.gz" -C "$fixture/data" .
WORLD_BACKUP_DIR="$fixture/world" COREPROTECT_BACKUP_DIR="$fixture/coreprotect" \
  "$root_dir/scripts/verify-backups.sh" >/dev/null
rm -f "$fixture/world/minecraft-20260101-020003.tar.gz" \
  "$fixture/data/plugins/DiscordSRV/messages.yml"

mkdir -p "$fixture/data/plugins/CoreProtect"
printf 'live sqlite journal\n' > "$fixture/data/plugins/CoreProtect/database.db-journal"
tar -czf "$fixture/world/minecraft-20260101-020004.tar.gz" -C "$fixture/data" .
if WORLD_BACKUP_DIR="$fixture/world" COREPROTECT_BACKUP_DIR="$fixture/coreprotect" \
    "$root_dir/scripts/verify-backups.sh" >/dev/null 2>&1; then
  echo "FAIL: world archive containing a live CoreProtect journal was accepted" >&2
  exit 1
fi
rm -f "$fixture/world/minecraft-20260101-020004.tar.gz" \
  "$fixture/data/plugins/CoreProtect/database.db-journal"

printf 'secret\n' > "$fixture/data/server.properties"
tar -czf "$fixture/world/minecraft-20260101-020005.tar.gz" -C "$fixture/data" .
if WORLD_BACKUP_DIR="$fixture/world" COREPROTECT_BACKUP_DIR="$fixture/coreprotect" \
    "$root_dir/scripts/verify-backups.sh" >/dev/null 2>&1; then
  echo "FAIL: world archive containing server.properties was accepted" >&2
  exit 1
fi
rm -f "$fixture/world/minecraft-20260101-020005.tar.gz" "$fixture/data/server.properties"

mkdir -p "$fixture/empty-data"
printf 'not a world\n' > "$fixture/empty-data/readme.txt"
tar -czf "$fixture/world/minecraft-20260101-020006.tar.gz" -C "$fixture/empty-data" .
if WORLD_BACKUP_DIR="$fixture/world" COREPROTECT_BACKUP_DIR="$fixture/coreprotect" \
    "$root_dir/scripts/verify-backups.sh" >/dev/null 2>&1; then
  echo "FAIL: archive without world/level.dat was accepted" >&2
  exit 1
fi
rm -f "$fixture/world/minecraft-20260101-020006.tar.gz"

: > "$fixture/data/world/level.dat"
tar -czf "$fixture/world/minecraft-20260101-020007.tar.gz" -C "$fixture/data" .
if WORLD_BACKUP_DIR="$fixture/world" COREPROTECT_BACKUP_DIR="$fixture/coreprotect" \
    "$root_dir/scripts/verify-backups.sh" >/dev/null 2>&1; then
  echo "FAIL: archive with empty world/level.dat was accepted" >&2
  exit 1
fi
rm -f "$fixture/world/minecraft-20260101-020007.tar.gz"
printf 'not gzip nbt\n' > "$fixture/data/world/level.dat"
tar -czf "$fixture/world/minecraft-20260101-020008.tar.gz" -C "$fixture/data" .
if WORLD_BACKUP_DIR="$fixture/world" COREPROTECT_BACKUP_DIR="$fixture/coreprotect" \
    "$root_dir/scripts/verify-backups.sh" >/dev/null 2>&1; then
  echo "FAIL: archive with invalid world/level.dat was accepted" >&2
  exit 1
fi
rm -f "$fixture/world/minecraft-20260101-020008.tar.gz"

printf 'first level\n' | gzip > "$fixture/data/world/level.dat"
tar -cf "$fixture/duplicate.tar" -C "$fixture/data" .
: > "$fixture/data/world/level.dat"
tar -rf "$fixture/duplicate.tar" -C "$fixture/data" ./world/level.dat
gzip -c "$fixture/duplicate.tar" > "$fixture/world/minecraft-20260101-020009.tar.gz"
if WORLD_BACKUP_DIR="$fixture/world" COREPROTECT_BACKUP_DIR="$fixture/coreprotect" \
    "$root_dir/scripts/verify-backups.sh" >/dev/null 2>&1; then
  echo "FAIL: archive with duplicate world/level.dat was accepted" >&2
  exit 1
fi
rm -f "$fixture/world/minecraft-20260101-020009.tar.gz" "$fixture/duplicate.tar"

rm -f "$fixture/data/world/level.dat"
ln -s ../../outside "$fixture/data/world/level.dat"
tar -czf "$fixture/world/minecraft-20260101-020010.tar.gz" -C "$fixture/data" .
if WORLD_BACKUP_DIR="$fixture/world" COREPROTECT_BACKUP_DIR="$fixture/coreprotect" \
    "$root_dir/scripts/verify-backups.sh" >/dev/null 2>&1; then
  echo "FAIL: archive with symlink world/level.dat was accepted" >&2
  exit 1
fi
rm -f "$fixture/world/minecraft-20260101-020010.tar.gz" "$fixture/data/world/level.dat"
printf 'level nbt fixture\n' | gzip > "$fixture/data/world/level.dat"

sqlite3 "$fixture/coreprotect-empty.db" 'VACUUM;'
gzip -c "$fixture/coreprotect-empty.db" > \
  "$fixture/coreprotect/coreprotect-empty.db.gz"
if WORLD_BACKUP_DIR="$fixture/world" COREPROTECT_BACKUP_DIR="$fixture/coreprotect" \
    "$root_dir/scripts/verify-backups.sh" >/dev/null 2>&1; then
  echo "FAIL: empty SQLite backup was accepted" >&2
  exit 1
fi
rm -f "$fixture/coreprotect/coreprotect-empty.db.gz"

mkdir -p "$fixture/unpaired-world" "$fixture/unpaired-coreprotect"
cp "$fixture/original-safe.tar.gz" \
  "$fixture/unpaired-world/minecraft-20260101-010000.tar.gz"
gzip -c "$fixture/coreprotect-test.db" > \
  "$fixture/unpaired-coreprotect/coreprotect-20260101-020000.db.gz"
if WORLD_BACKUP_DIR="$fixture/unpaired-world" \
    COREPROTECT_BACKUP_DIR="$fixture/unpaired-coreprotect" \
    "$root_dir/scripts/verify-backups.sh" >/dev/null 2>&1; then
  echo "FAIL: world without an earlier CoreProtect archive was accepted" >&2
  exit 1
fi

mkdir -p "$fixture/same-second-world" "$fixture/same-second-coreprotect"
cp "$fixture/original-safe.tar.gz" \
  "$fixture/same-second-world/minecraft-20260101-020000.tar.gz"
gzip -c "$fixture/coreprotect-test.db" > \
  "$fixture/same-second-coreprotect/coreprotect-20260101-020000.db.gz"
if WORLD_BACKUP_DIR="$fixture/same-second-world" \
    COREPROTECT_BACKUP_DIR="$fixture/same-second-coreprotect" \
    "$root_dir/scripts/verify-backups.sh" >/dev/null 2>&1; then
  echo "FAIL: same-second CoreProtect archive was accepted as earlier" >&2
  exit 1
fi

mkdir -p "$fixture/unparseable-world" "$fixture/unparseable-coreprotect"
cp "$fixture/original-safe.tar.gz" \
  "$fixture/unparseable-world/minecraft-manual.tar.gz"
gzip -c "$fixture/coreprotect-test.db" > \
  "$fixture/unparseable-coreprotect/coreprotect-20260101-010000.db.gz"
if WORLD_BACKUP_DIR="$fixture/unparseable-world" \
    COREPROTECT_BACKUP_DIR="$fixture/unparseable-coreprotect" \
    "$root_dir/scripts/verify-backups.sh" >/dev/null 2>&1; then
  echo "FAIL: world archive without a timestamp was accepted" >&2
  exit 1
fi

printf 'not a sqlite database\n' | gzip > "$fixture/coreprotect/coreprotect-corrupt.db.gz"
if WORLD_BACKUP_DIR="$fixture/world" COREPROTECT_BACKUP_DIR="$fixture/coreprotect" \
    "$root_dir/scripts/verify-backups.sh" >/dev/null 2>&1; then
  echo "FAIL: invalid CoreProtect database was accepted" >&2
  exit 1
fi

echo "OK: backup verification fixtures passed"
