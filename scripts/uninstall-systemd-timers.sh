#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
unit_dir="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
systemctl_bin="${SYSTEMCTL_BIN:-systemctl}"
maintenance_file="${COREPROTECT_MAINTENANCE_FILE:-$root_dir/.coreprotect-maintenance}"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: root 権限が必要です。sudo で実行してください: sudo $0" >&2
  exit 1
fi

timers=(
  mc-coreprotect-db-backup.timer
  mc-coreprotect-purge.timer
)
units=(
  "$unit_dir/mc-coreprotect-db-backup.service"
  "$unit_dir/mc-coreprotect-db-backup.timer"
  "$unit_dir/mc-coreprotect-purge.service"
  "$unit_dir/mc-coreprotect-purge.timer"
)
services=(
  mc-coreprotect-db-backup.service
  mc-coreprotect-purge.service
)

# 途中で停止に失敗した場合も定期処理を再開させない
install -m 0600 /dev/null "$maintenance_file"

for timer in "${timers[@]}"; do
  if ! unit_file_state="$(
    "$systemctl_bin" list-unit-files "$timer" --no-legend 2>/dev/null
  )"; then
    echo "ERROR: $timer の有効化状態を確認できませんでした" >&2
    exit 1
  fi
  if [ -n "$unit_file_state" ]; then
    "$systemctl_bin" disable --now "$timer"
  fi
done

for unit in "${timers[@]}" "${services[@]}"; do
  state="$("$systemctl_bin" show --property=ActiveState --value "$unit")"
  case "$state" in
    inactive | failed) ;;
    active | activating | reloading | deactivating | maintenance | refreshing)
      "$systemctl_bin" stop "$unit"
      ;;
    *)
      echo "ERROR: $unit の状態を確認できませんでした: ${state:-unknown}" >&2
      exit 1
      ;;
  esac
done

for unit in "${timers[@]}" "${services[@]}"; do
  state="$("$systemctl_bin" show --property=ActiveState --value "$unit")"
  case "$state" in
    inactive | failed) ;;
    *)
      echo "ERROR: $unit を停止できませんでした: ${state:-unknown}" >&2
      exit 1
      ;;
  esac
done

rm -f -- "${units[@]}"
"$systemctl_bin" daemon-reload
"$systemctl_bin" reset-failed \
  mc-coreprotect-db-backup.service \
  mc-coreprotect-purge.service 2>/dev/null || true
rm -f -- "$maintenance_file"

echo "OK: CoreProtect の systemd timer を削除しました"
