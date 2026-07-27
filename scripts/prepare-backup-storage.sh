#!/usr/bin/env sh
set -eu

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
project_root="${MC_PROJECT_ROOT:-$(CDPATH= cd -- "$script_dir/.." && pwd)}"
env_file="${MC_ENV_FILE:-$project_root/.env}"

if [ "$#" -gt 1 ]; then
  echo "usage: $0 [expected-absolute-backup-path]" >&2
  exit 2
fi
if [ ! -f "$env_file" ]; then
  echo "ERROR: 設定ファイルがありません: $env_file" >&2
  exit 1
fi

MC_ENV_FILE="$env_file" "$script_dir/check-runtime-identity.sh" >/dev/null

backup_root="$(MC_ENV_FILE="$env_file" "$script_dir/backup-root.sh" --create)"
if [ "$#" -eq 1 ]; then
  expected_root="$(BACKUP_ROOT="$1" MC_ENV_FILE="$env_file" \
    "$script_dir/backup-root.sh" --create)"
  if [ "$backup_root" != "$expected_root" ]; then
    echo "ERROR: 引数と $env_file の BACKUP_ROOT が一致しません" >&2
    exit 1
  fi
fi

sentinel="$backup_root/world/.mc-backup-world-v1"
if [ -L "$sentinel" ] || { [ -e "$sentinel" ] && [ ! -f "$sentinel" ]; }; then
  echo "ERROR: バックアップ保存先の sentinel が通常ファイルではありません: $sentinel" >&2
  exit 1
fi
if [ -e "$sentinel" ]; then
  if [ "$(cat "$sentinel")" != 'mc-backup-world-v1' ]; then
    echo "ERROR: バックアップ保存先の sentinel が一致しません: $sentinel" >&2
    exit 1
  fi
else
  printf 'mc-backup-world-v1\n' > "$sentinel"
  chmod 0600 "$sentinel"
  sync
fi

echo "OK: バックアップ保存先を準備しました ($backup_root)"
