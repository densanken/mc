#!/usr/bin/env bash
set -euo pipefail

# CoreProtect の定期 purge と DB backup 用 systemd timer を設置する
# unit の設置には root 権限が必要なため、本番 Ubuntu host で sudo を付けて実行する
#
#   sudo ./scripts/install-systemd-timers.sh
#
# 作成する timer
#   mc-coreprotect-purge.timer      毎週月曜 04:30 に /co purge t:30d を実行
#   mc-coreprotect-db-backup.timer  毎時 SQLite online backup を実行
#                                   (保持世代数は coreprotect-backup-db.sh の KEEP_GENERATIONS が正)
#
# OnCalendar は host の timezone で解釈する
# JST で実行する場合は host の timezone が Asia/Tokyo であることを timedatectl で確認する

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
unit_dir="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
systemctl_bin="${SYSTEMCTL_BIN:-systemctl}"
sqlite3_bin="${SQLITE3_BIN:-sqlite3}"
flock_bin="${FLOCK_BIN:-flock}"
run_user="${SUDO_USER:-$(id -un)}"
runuser_bin="${RUNUSER_BIN:-runuser}"
maintenance_file="${COREPROTECT_MAINTENANCE_FILE:-$root_dir/.coreprotect-maintenance}"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: root 権限が必要です。sudo で実行してください: sudo $0" >&2
  exit 1
fi

if [ "$run_user" = "root" ]; then
  echo "ERROR: docker compose を操作する一般ユーザーで sudo 実行してください" >&2
  exit 1
fi

if ! id -nG "$run_user" | tr ' ' '\n' | grep -qx docker; then
  echo "ERROR: $run_user は docker group に入っていません" >&2
  exit 1
fi
if ! command -v "$sqlite3_bin" >/dev/null 2>&1; then
  echo "ERROR: CoreProtect DB のバックアップに sqlite3 が必要です" >&2
  exit 1
fi
if ! command -v "$flock_bin" >/dev/null 2>&1; then
  echo "ERROR: CoreProtect DB backup の排他制御に flock が必要です" >&2
  exit 1
fi
if ! command -v "$runuser_bin" >/dev/null 2>&1; then
  echo "ERROR: 実行ユーザーの権限確認に runuser が必要です" >&2
  exit 1
fi
"$runuser_bin" -u "$run_user" -- "$root_dir/scripts/check-runtime-identity.sh" >/dev/null
"$runuser_bin" -u "$run_user" -- "$root_dir/scripts/backup-root.sh" >/dev/null
case "$root_dir" in
  *[[:space:]]* | *%* | *\"* | *\\*)
    echo "ERROR: systemd unit に使用できない文字を配置パスに含んでいます: $root_dir" >&2
    exit 1
    ;;
esac
if [ ! -d "$unit_dir" ]; then
  echo "ERROR: systemd unit の配置先がありません: $unit_dir" >&2
  exit 1
fi

cat > "$unit_dir/mc-coreprotect-purge.service" <<EOF
[Unit]
Description=CoreProtect purge (30 days retention)
Requires=docker.service
After=docker.service
ConditionPathExists=!$maintenance_file
StartLimitIntervalSec=12h
StartLimitBurst=144

[Service]
Type=oneshot
User=$run_user
WorkingDirectory=$root_dir
ExecStart=$root_dir/scripts/coreprotect-purge-30d.sh
Restart=on-failure
RestartSec=5m
EOF

cat > "$unit_dir/mc-coreprotect-purge.timer" <<EOF
[Unit]
Description=Weekly CoreProtect purge

[Timer]
# purge は負荷が高いため、プレイヤーの少ない時間帯に実行する
OnCalendar=Mon *-*-* 04:30:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

cat > "$unit_dir/mc-coreprotect-db-backup.service" <<EOF
[Unit]
Description=CoreProtect SQLite online backup (see coreprotect-backup-db.sh for retention)
ConditionPathExists=!$maintenance_file
Wants=local-fs.target remote-fs.target
After=local-fs.target remote-fs.target
StartLimitIntervalSec=12h
StartLimitBurst=144

[Service]
Type=oneshot
User=$run_user
WorkingDirectory=$root_dir
ExecStart=$root_dir/scripts/coreprotect-backup-db.sh
Restart=on-failure
RestartSec=5m
EOF

cat > "$unit_dir/mc-coreprotect-db-backup.timer" <<EOF
[Unit]
Description=Hourly CoreProtect DB backup

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
EOF

"$systemctl_bin" daemon-reload
"$systemctl_bin" enable --now mc-coreprotect-purge.timer mc-coreprotect-db-backup.timer
"$systemctl_bin" list-timers 'mc-coreprotect-*' --no-pager
