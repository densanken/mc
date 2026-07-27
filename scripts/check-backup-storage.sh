#!/usr/bin/env sh
set -eu

storage_dir="${BACKUP_STORAGE_DIR:-/backups}"
sentinel="$storage_dir/.mc-backup-world-v1"
if [ -L "$sentinel" ] || [ ! -f "$sentinel" ] ||
    [ "$(cat "$sentinel")" != 'mc-backup-world-v1' ]; then
  echo "ERROR: バックアップ保存先の sentinel を確認できません" >&2
  exit 1
fi

umask 077
probe="$(mktemp "$storage_dir/.write-probe.XXXXXX")"
cleanup() {
  rm -f "$probe"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
printf 'backup-storage-write-probe\n' > "$probe"
sync
rm -f "$probe"
probe=""
trap - EXIT HUP INT TERM
