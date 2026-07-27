#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
DB_PATH="${1:-$root_dir/minecraft/plugins/CoreProtect/database.db}"
if [ "$#" -ge 2 ]; then
  BACKUP_DIR="$2"
  world_backup_dir="${WORLD_BACKUP_DIR:-}"
else
  backup_root="$("$root_dir/scripts/backup-root.sh")"
  BACKUP_DIR="$backup_root/coreprotect"
  world_backup_dir="${WORLD_BACKUP_DIR:-$backup_root/world}"
fi
KEEP_GENERATIONS="${KEEP_GENERATIONS:-100}"
FLOCK_BIN="${FLOCK_BIN:-flock}"
LOCK_PATH="${COREPROTECT_BACKUP_LOCK_PATH:-$root_dir/.coreprotect-backup.lock}"
umask 077
tmp_db=""
tmp_archive=""
retention_reference=""

cleanup() {
  [ -z "$tmp_db" ] || rm -f -- "$tmp_db"
  [ -z "$tmp_archive" ] || rm -f -- "$tmp_archive"
  [ -z "$retention_reference" ] || rm -f -- "$retention_reference"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "ERROR: sqlite3 が見つかりません。Ubuntu では apt などで sqlite3 を入れてください" >&2
  exit 1
fi
if ! command -v "$FLOCK_BIN" >/dev/null 2>&1; then
  echo "ERROR: CoreProtect DB backup の排他制御に flock が必要です" >&2
  exit 1
fi

if [ ! -f "$DB_PATH" ]; then
  echo "ERROR: CoreProtect DB が見つかりません: $DB_PATH" >&2
  exit 1
fi

case "$KEEP_GENERATIONS" in
  '' | *[!0-9]* | 0)
    echo "ERROR: KEEP_GENERATIONS は正の整数で指定してください" >&2
    exit 2
    ;;
esac

mkdir -p "$BACKUP_DIR"

if [ -L "$LOCK_PATH" ] || { [ -e "$LOCK_PATH" ] && [ ! -f "$LOCK_PATH" ]; }; then
  echo "ERROR: CoreProtect DB backup の lock が通常ファイルではありません: $LOCK_PATH" >&2
  exit 1
fi
exec 9>>"$LOCK_PATH"
if [ -L "$LOCK_PATH" ] || [ ! -f "$LOCK_PATH" ] ||
    ! "$FLOCK_BIN" -n 9; then
  echo "ERROR: CoreProtect DB backup はすでに実行中か lock が不正です: $LOCK_PATH" >&2
  exit 1
fi

# world バックアップコンテナの TZ と揃え、ファイル名を実時間順に比較できるようにする
timestamp="$(TZ=Asia/Tokyo date +%Y%m%d-%H%M%S)"
output="$BACKUP_DIR/coreprotect-$timestamp.db.gz"
suffix=1
while [ -e "$output" ]; do
  output="$BACKUP_DIR/coreprotect-$timestamp-$suffix.db.gz"
  suffix=$((suffix + 1))
done

tmp_db="$(mktemp "$BACKUP_DIR/.coreprotect-db.XXXXXX")"
tmp_archive="$(mktemp "$BACKUP_DIR/.coreprotect-archive.XXXXXX")"

# 稼働中 SQLite DB は単純コピーせず、online backup API で取得する
sqlite3 "$DB_PATH" ".backup '$tmp_db'"
integrity="$(sqlite3 "$tmp_db" 'PRAGMA integrity_check;')"
if [ "$integrity" != "ok" ]; then
  echo "ERROR: CoreProtect DB backup の integrity_check に失敗しました: $integrity" >&2
  exit 1
fi

gzip -c "$tmp_db" > "$tmp_archive"
gzip -t "$tmp_archive"
chmod 0600 "$tmp_archive"
while ! ln "$tmp_archive" "$output" 2>/dev/null; do
  if [ ! -e "$output" ]; then
    echo "ERROR: CoreProtect DB backup を公開できませんでした: $output" >&2
    exit 1
  fi
  output="$BACKUP_DIR/coreprotect-$timestamp-$suffix.db.gz"
  suffix=$((suffix + 1))
done
rm -f "$tmp_archive"
tmp_archive=""
rm -f -- "$tmp_db"
tmp_db=""

echo "$output"

# 最新の KEEP_GENERATIONS 世代と、保存済み world の復元に必要な世代を残す
shopt -s nullglob
backups=("$BACKUP_DIR"/coreprotect-*.db.gz)
if [ "${#backups[@]}" -gt "$KEEP_GENERATIONS" ]; then
  retention_reference="$(mktemp "$BACKUP_DIR/.retention-time.XXXXXX")"
  old_backups=()
  for backup in "${backups[@]}"; do
    if [ -L "$backup" ] || [ ! -f "$backup" ] || [ "$backup" -nt "$retention_reference" ] ||
        ! gzip -t "$backup"; then
      echo "ERROR: 保持数を適用できないバックアップがあります: $backup" >&2
      exit 1
    fi
    [ "$backup" = "$output" ] || old_backups+=("$backup")
  done

  protected_backups=()
  if [ -n "$world_backup_dir" ]; then
    for world_backup in "$world_backup_dir"/minecraft-*.tar.gz; do
      # world 側のローテーションで走査直後に消えた場合は、次の候補へ進む
      if [ ! -e "$world_backup" ] && [ ! -L "$world_backup" ]; then
        continue
      fi
      if [ -L "$world_backup" ] || [ ! -f "$world_backup" ]; then
        echo "ERROR: world バックアップが通常ファイルではありません: $world_backup" >&2
        exit 1
      fi

      world_name="${world_backup##*/}"
      if [[ ! "$world_name" =~ ^minecraft-([0-9]{8}-[0-9]{6})(-[0-9]+)?\.tar\.gz$ ]]; then
        # 作成時刻が読めない world には対応する CoreProtect 世代を追加保持しない
        echo "WARNING: world バックアップの作成時刻を判定できないため、対応する CoreProtect 世代を追加保持しません: $world_backup" >&2
        continue
      fi
      world_timestamp="${BASH_REMATCH[1]}"
      anchor=""
      anchor_timestamp=""
      anchor_sequence=0
      for backup in "${backups[@]}"; do
        backup_name="${backup##*/}"
        if [[ "$backup_name" =~ ^coreprotect-([0-9]{8}-[0-9]{6})(-[0-9]+)?\.db\.gz$ ]]; then
          backup_timestamp="${BASH_REMATCH[1]}"
          backup_sequence="${BASH_REMATCH[2]:--0}"
          backup_sequence="${backup_sequence#-}"
          if [[ "$backup_timestamp" < "$world_timestamp" ]]; then
            if [ -z "$anchor" ] ||
                [[ "$anchor_timestamp" < "$backup_timestamp" ]]; then
              anchor="$backup"
              anchor_timestamp="$backup_timestamp"
              anchor_sequence="$backup_sequence"
            elif [[ "$anchor_timestamp" == "$backup_timestamp" ]] &&
                [ "$backup_sequence" -gt "$anchor_sequence" ]; then
              anchor="$backup"
              anchor_sequence="$backup_sequence"
            fi
          fi
        fi
      done
      if [ -n "$anchor" ]; then
        protected_backups+=("$anchor")
      else
        echo "WARNING: world より前の CoreProtect バックアップがありません: $world_backup" >&2
      fi
    done
  fi

  keep_old=$((KEEP_GENERATIONS - 1))
  prune_list=""
  if [ "${#old_backups[@]}" -gt "$keep_old" ]; then
    # 対象はこの script が生成した coreprotect-*.db.gz のみで、空白や改行を含まない
    # shellcheck disable=SC2012
    prune_list="$(ls -1t "${old_backups[@]}" | tail -n +$((keep_old + 1)))"
  fi
  while IFS= read -r old; do
    [ -n "$old" ] || continue
    protected=false
    # Bash 3.2 では set -u と空配列を組み合わせると通常の "${array[@]}" が失敗する
    # shellcheck disable=SC1083
    for protected_backup in ${protected_backups[@]+"${protected_backups[@]}"}; do
      if [ "$old" = "$protected_backup" ]; then
        protected=true
        break
      fi
    done
    if "$protected"; then
      echo "retained for world restore: $old"
      continue
    fi
    rm -f -- "$old"
    echo "pruned: $old"
  done <<< "$prune_list"
fi
