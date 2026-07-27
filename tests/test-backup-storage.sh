#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$(mktemp -d)"
fixture="$(cd "$fixture" && pwd -P)"
trap 'rm -rf "$fixture"' EXIT

project="$fixture/project"
external="$fixture/external"
env_file="$project/.env"
mkdir -p "$project"
printf 'BACKUP_ROOT=%s\n' "$external" > "$env_file"

actual="$(
  MC_PROJECT_ROOT="$project" MC_ENV_FILE="$env_file" \
    "$root_dir/scripts/backup-root.sh" --create
)"
if [ "$actual" != "$external" ]; then
  echo "FAIL: unexpected backup root: $actual" >&2
  exit 1
fi
for directory in world coreprotect quarantine; do
  if [ ! -d "$external/$directory" ] || [ ! -w "$external/$directory" ]; then
    echo "FAIL: backup directory was not prepared: $directory" >&2
    exit 1
  fi
done

printf 'BACKUP_ROOT=relative/backups\n' > "$env_file"
if MC_PROJECT_ROOT="$project" MC_ENV_FILE="$env_file" \
    "$root_dir/scripts/backup-root.sh" --create >/dev/null 2>&1; then
  echo "FAIL: relative backup root was accepted" >&2
  exit 1
fi
printf 'BACKUP_ROOT=%s\n' "$project/backups" > "$env_file"
if MC_PROJECT_ROOT="$project" MC_ENV_FILE="$env_file" \
    "$root_dir/scripts/backup-root.sh" --create >/dev/null 2>&1; then
  echo "FAIL: in-project backup root was accepted" >&2
  exit 1
fi
printf 'BACKUP_ROOT=%s\n' "$fixture/other/../project/backups" > "$env_file"
if MC_PROJECT_ROOT="$project" MC_ENV_FILE="$env_file" \
    "$root_dir/scripts/backup-root.sh" --create >/dev/null 2>&1; then
  echo "FAIL: backup root containing .. was accepted" >&2
  exit 1
fi
printf 'BACKUP_ROOT=/\n' > "$env_file"
if MC_PROJECT_ROOT="$project" MC_ENV_FILE="$env_file" \
    "$root_dir/scripts/backup-root.sh" --create >/dev/null 2>&1; then
  echo "FAIL: filesystem root was accepted as backup root" >&2
  exit 1
fi
for invalid_root in // /./ "$fixture//external"; do
  printf 'BACKUP_ROOT=%s\n' "$invalid_root" > "$env_file"
  if MC_PROJECT_ROOT="$project" MC_ENV_FILE="$env_file" \
      "$root_dir/scripts/backup-root.sh" --create >/dev/null 2>&1; then
    echo "FAIL: non-normalized backup root was accepted: $invalid_root" >&2
    exit 1
  fi
done

printf 'BACKUP_ROOT=%s\n' "$external" > "$env_file"
rm -rf "$external/quarantine"
if MC_PROJECT_ROOT="$project" MC_ENV_FILE="$env_file" \
    "$root_dir/scripts/backup-root.sh" >/dev/null 2>&1; then
  echo "FAIL: missing backup subdirectory was accepted without --create" >&2
  exit 1
fi
MC_PROJECT_ROOT="$project" MC_ENV_FILE="$env_file" \
  "$root_dir/scripts/backup-root.sh" --create >/dev/null

printf 'survives project deletion\n' > "$external/world/minecraft-survival.tar.gz"
sqlite3 "$project/database.db" \
  'CREATE TABLE block_log (id INTEGER PRIMARY KEY, material TEXT);'
MC_PROJECT_ROOT="$project" MC_ENV_FILE="$env_file" \
  "$root_dir/scripts/coreprotect-backup-db.sh" "$project/database.db" >/dev/null
rm -rf "$project"
if [ ! -f "$external/world/minecraft-survival.tar.gz" ]; then
  echo "FAIL: backup was removed with the project directory" >&2
  exit 1
fi
if ! find "$external/coreprotect" -maxdepth 1 -type f \
    -name 'coreprotect-*.db.gz' -print -quit | grep -q .; then
  echo "FAIL: CoreProtect backup was removed with the project directory" >&2
  exit 1
fi

mkdir -p "$project"
: > "$env_file"
if MC_PROJECT_ROOT="$project" MC_ENV_FILE="$env_file" \
    "$root_dir/scripts/prepare-backup-storage.sh" >/dev/null 2>&1; then
  echo "FAIL: backup preparation accepted missing UID/GID and BACKUP_ROOT" >&2
  exit 1
fi
printf 'MINECRAFT_UID=%s\nMINECRAFT_GID=%s\nBACKUP_ROOT=%s\n' \
  "$(id -u)" "$(id -g)" "$external" > "$env_file"
MC_PROJECT_ROOT="$project" MC_ENV_FILE="$env_file" \
  "$root_dir/scripts/prepare-backup-storage.sh" "$external" >/dev/null

printf 'MINECRAFT_UID=999999\nMINECRAFT_GID=%s\nBACKUP_ROOT=%s\n' \
  "$(id -g)" "$external" > "$env_file"
if MC_PROJECT_ROOT="$project" MC_ENV_FILE="$env_file" \
    "$root_dir/scripts/prepare-backup-storage.sh" "$external" >/dev/null 2>&1; then
  echo "FAIL: backup preparation accepted a mismatched Minecraft UID" >&2
  exit 1
fi

echo "OK: external backup storage fixtures passed"
