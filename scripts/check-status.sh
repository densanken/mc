#!/usr/bin/env sh
set -eu

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
docker_bin="${DOCKER_BIN:-docker}"
systemctl_bin="${SYSTEMCTL_BIN:-systemctl}"
verify_backups_runner="${VERIFY_BACKUPS_RUNNER:-$script_dir/verify-backups.sh}"
coreprotect_maintenance_file="${COREPROTECT_MAINTENANCE_FILE:-$script_dir/../.coreprotect-maintenance}"
coreprotect_max_age_minutes="${COREPROTECT_BACKUP_MAX_AGE_MINUTES:-120}"
ansi_escape="$(printf '\033')"

normalize_rcon_response() {
  printf '%s' "$1" |
    sed "s/${ansi_escape}\\[[0-9;]*m//g" |
    tr -d '\r\n'
}

case "$coreprotect_max_age_minutes" in
  '' | *[!0-9]* | 0)
    echo "ERROR: COREPROTECT_BACKUP_MAX_AGE_MINUTES は正の整数で指定してください" >&2
    exit 2
    ;;
esac

if [ -n "${COREPROTECT_BACKUP_DIR:-}" ]; then
  coreprotect_backup_dir="$COREPROTECT_BACKUP_DIR"
else
  backup_root="$("$script_dir/backup-root.sh")"
  coreprotect_backup_dir="$backup_root/coreprotect"
fi

"$docker_bin" compose ps
"$docker_bin" compose logs --tail=80 minecraft

failures=0

if [ -e "$coreprotect_maintenance_file" ]; then
  echo "ERROR: CoreProtect の定期処理が保守のため停止したままです" >&2
  failures=$((failures + 1))
fi

minecraft_id="$("$docker_bin" compose ps --status running --quiet minecraft 2>/dev/null || true)"
if [ -z "$minecraft_id" ]; then
  echo "ERROR: minecraft が稼働していません" >&2
  failures=$((failures + 1))
elif [ "$("$docker_bin" inspect --format '{{.State.Health.Status}}' "$minecraft_id" 2>/dev/null || true)" != "healthy" ]; then
  echo "ERROR: minecraft が healthy ではありません" >&2
  failures=$((failures + 1))
fi

plugin_health="$(
  "$docker_bin" compose exec -T minecraft rcon-cli discordguildgate plugins 2>/dev/null || true
)"
plugin_health="$(normalize_rcon_response "$plugin_health")"
# DiscordGuildGate は全必須プラグインが有効な場合だけ ENABLED を返す
if ! printf '%s\n' "$plugin_health" | grep -Eq '^ENABLED required-plugins=[1-9][0-9]*$'; then
  echo "ERROR: 必須プラグインがすべて有効ではありません (${plugin_health:-no response})" >&2
  failures=$((failures + 1))
fi

backups_id="$("$docker_bin" compose ps --status running --quiet backups 2>/dev/null || true)"
if [ -z "$backups_id" ]; then
  echo "ERROR: backups が稼働していません" >&2
  failures=$((failures + 1))
elif [ "$("$docker_bin" inspect --format '{{.State.Health.Status}}' \
    "$backups_id" 2>/dev/null || true)" != healthy ]; then
  echo "ERROR: backups の保存先 healthcheck が成功していません" >&2
  failures=$((failures + 1))
fi

for required_unit in \
  mc-coreprotect-db-backup.timer \
  mc-coreprotect-purge.timer
do
  if ! "$systemctl_bin" is-active --quiet "$required_unit"; then
    echo "ERROR: $required_unit が active ではありません" >&2
    failures=$((failures + 1))
  fi
done

for required_service in \
  mc-coreprotect-db-backup.service \
  mc-coreprotect-purge.service
do
  if "$systemctl_bin" is-failed --quiet "$required_service"; then
    echo "ERROR: $required_service が失敗状態です" >&2
    failures=$((failures + 1))
  fi
done

recent_coreprotect_candidates="$(
  find "$coreprotect_backup_dir" -maxdepth 1 -type f \
    -name 'coreprotect-*.db.gz' -mmin "-$coreprotect_max_age_minutes" -print \
    2>/dev/null || true
)"
time_reference="$(mktemp "${TMPDIR:-/tmp}/mc-status-time.XXXXXX")"
trap 'rm -f "$time_reference"' EXIT
recent_coreprotect_backup=""
while IFS= read -r candidate; do
  [ -n "$candidate" ] || continue
  if [ ! -f "$candidate" ] || [ -L "$candidate" ]; then
    continue
  fi
  # 実行環境の dash と busybox sh は test -nt に対応する
  # shellcheck disable=SC3013
  if [ ! "$candidate" -nt "$time_reference" ]; then
    recent_coreprotect_backup="$candidate"
    break
  fi
done <<EOF
$recent_coreprotect_candidates
EOF
if [ -z "$recent_coreprotect_backup" ]; then
  echo "ERROR: 過去 $coreprotect_max_age_minutes 分以内の CoreProtect バックアップがありません" >&2
  failures=$((failures + 1))
fi

playit_id="$("$docker_bin" compose ps --status running --quiet playit 2>/dev/null || true)"
if [ -n "$playit_id" ]; then
  status="$("$docker_bin" compose exec -T minecraft rcon-cli discordguildgate status 2>/dev/null || true)"
  status="$(normalize_rcon_response "$status")"
  if ! printf '%s\n' "$status" | grep -Eq '^READY allowed-guilds=[1-9][0-9]*$'; then
    echo "ERROR: playit の稼働中に Discord の参加制限が READY ではありません (${status:-no response})" >&2
    failures=$((failures + 1))
  else
    echo "OK: playit の稼働中も Discord の参加制限は READY です ($status)"
  fi
else
  echo "OK: playit は稼働していません（非公開）"
fi

if ! "$verify_backups_runner"; then
  failures=$((failures + 1))
fi

if [ "$failures" -gt 0 ]; then
  echo "ERROR: $failures 件の状態異常があります" >&2
  exit 1
fi

echo "OK: 必須サービス、プラグイン、参加制限、バックアップを確認しました"
