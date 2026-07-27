#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
timer_installer="$root_dir/scripts/install-systemd-timers.sh"
timer_uninstaller="$root_dir/scripts/uninstall-systemd-timers.sh"
fixture="$(mktemp -d)"
fixture="$(cd "$fixture" && pwd -P)"
trap 'rm -rf "$fixture"' EXIT
export BACKUP_ROOT="$fixture/external-backups"
mkdir -p "$BACKUP_ROOT/world" "$BACKUP_ROOT/coreprotect" "$BACKUP_ROOT/quarantine"
export MC_ENV_FILE="$fixture/runtime.env"
export TEST_RUNTIME_PATH="$PATH"
printf 'MINECRAFT_UID=%s\nMINECRAFT_GID=%s\nBACKUP_ROOT=%s\n' \
  "$(id -u)" "$(id -g)" "$BACKUP_ROOT" > "$MC_ENV_FILE"

# installer の source にある literal な $maintenance_file を検索する
# shellcheck disable=SC2016
if [ "$(grep -Fc 'ConditionPathExists=!$maintenance_file' "$timer_installer")" -ne 2 ]; then
  echo "FAIL: CoreProtect services do not honor the maintenance marker" >&2
  exit 1
fi
for setting in \
  'Restart=on-failure' \
  'RestartSec=5m' \
  'StartLimitIntervalSec=12h' \
  'StartLimitBurst=144'
do
  if ! grep -Fq "$setting" "$timer_installer"; then
    echo "FAIL: CoreProtect purge retry setting is missing: $setting" >&2
    exit 1
  fi
done

actual_user="$(id -un)"
actual_group="$(id -gn)"
cat > "$fixture/id" <<'ID'
#!/usr/bin/env sh
case "$1" in
  -u) printf '0\n' ;;
  -gn) printf '%s\n' "$TEST_RUN_GROUP" ;;
  -nG)
    if [ "${NO_DOCKER_GROUP:-false}" = true ]; then
      printf '%s\n' "$TEST_RUN_GROUP"
    else
      printf 'docker %s\n' "$TEST_RUN_GROUP"
    fi
    ;;
  *) exit 1 ;;
esac
ID
cat > "$fixture/flock" <<'FLOCK'
#!/usr/bin/env sh
exit 0
FLOCK
cat > "$fixture/runuser" <<'RUNUSER'
#!/usr/bin/env sh
[ "${RUNUSER_FAIL:-false}" != true ] || exit 1
shift 3
PATH="$TEST_RUNTIME_PATH" exec "$@"
RUNUSER
cat > "$fixture/systemctl" <<'SYSTEMCTL'
#!/usr/bin/env sh
printf '%s\n' "$*" >> "$SYSTEMCTL_TEST_LOG"
case "$1" in
  is-active) printf 'active\n' ;;
  list-unit-files)
    [ "${LIST_FAIL:-false}" != true ] || exit 1
    if [ -n "${UNIT_TEST_DIR:-}" ] && [ -e "$UNIT_TEST_DIR/$2" ]; then
      printf '%s enabled\n' "$2"
    fi
    ;;
  stop)
    [ "${STOP_FAIL:-false}" != true ]
    if [ -n "${STOPPED_STATE_DIR:-}" ]; then
      : > "$STOPPED_STATE_DIR/$2"
    fi
    ;;
  show)
    unit="${4:-}"
    if [ -n "${ACTIVE_WITHOUT_FILE_UNIT:-}" ] &&
      [ "$unit" = "$ACTIVE_WITHOUT_FILE_UNIT" ] &&
      { [ -z "${STOPPED_STATE_DIR:-}" ] || [ ! -e "$STOPPED_STATE_DIR/$unit" ]; }; then
      printf 'active\n'
    else
      printf '%s\n' "${UNIT_ACTIVE_STATE:-inactive}"
    fi
    ;;
esac
SYSTEMCTL
cat > "$fixture/sqlite3" <<'SQLITE3'
#!/usr/bin/env sh
exit 0
SQLITE3
chmod 0755 \
  "$fixture/id" "$fixture/flock" "$fixture/runuser" \
  "$fixture/systemctl" "$fixture/sqlite3"

mkdir -p "$fixture/units"
: > "$fixture/timer-install.log"
PATH="$fixture:$PATH" TEST_RUN_GROUP="$actual_group" SUDO_USER="$actual_user" \
SYSTEMCTL_TEST_LOG="$fixture/timer-install.log" SYSTEMCTL_BIN="$fixture/systemctl" \
SYSTEMD_UNIT_DIR="$fixture/units" COREPROTECT_MAINTENANCE_FILE="$fixture/maintenance" \
SQLITE3_BIN="$fixture/sqlite3" RUNUSER_BIN="$fixture/runuser" \
  "$timer_installer" >/dev/null
for unit in \
  mc-coreprotect-db-backup.service \
  mc-coreprotect-db-backup.timer \
  mc-coreprotect-purge.service \
  mc-coreprotect-purge.timer
do
  if [ ! -f "$fixture/units/$unit" ]; then
    echo "FAIL: CoreProtect timer installer did not create $unit" >&2
    exit 1
  fi
done
if ! grep -Fqx \
    'enable --now mc-coreprotect-purge.timer mc-coreprotect-db-backup.timer' \
    "$fixture/timer-install.log"; then
  echo "FAIL: CoreProtect timer installer did not enable both timers" >&2
  exit 1
fi
if grep -Fq 'Environment=BACKUP_ROOT=' \
    "$fixture/units/mc-coreprotect-db-backup.service"; then
  echo "FAIL: CoreProtect backup unit keeps a stale BACKUP_ROOT snapshot" >&2
  exit 1
fi
if grep -Fq 'RequiresMountsFor=' \
    "$fixture/units/mc-coreprotect-db-backup.service" ||
    ! grep -Fqx 'Wants=local-fs.target remote-fs.target' \
      "$fixture/units/mc-coreprotect-db-backup.service" ||
    ! grep -Fqx 'Restart=on-failure' \
      "$fixture/units/mc-coreprotect-db-backup.service"; then
  echo "FAIL: CoreProtect backup unit does not retry after storage recovery" >&2
  exit 1
fi

if PATH="$fixture:$PATH" TEST_RUN_GROUP="$actual_group" SUDO_USER=root \
    SYSTEMCTL_TEST_LOG="$fixture/root-rejected.log" SYSTEMCTL_BIN="$fixture/systemctl" \
    SYSTEMD_UNIT_DIR="$fixture/units" SQLITE3_BIN="$fixture/sqlite3" \
      "$timer_installer" >/dev/null 2>&1; then
  echo "FAIL: CoreProtect timer installer accepted root as the runtime user" >&2
  exit 1
fi
if PATH="$fixture:$PATH" TEST_RUN_GROUP="$actual_group" SUDO_USER="$actual_user" \
    NO_DOCKER_GROUP=true SYSTEMCTL_TEST_LOG="$fixture/group-rejected.log" \
    SYSTEMCTL_BIN="$fixture/systemctl" SYSTEMD_UNIT_DIR="$fixture/units" \
    SQLITE3_BIN="$fixture/sqlite3" \
      "$timer_installer" >/dev/null 2>&1; then
  echo "FAIL: CoreProtect timer installer accepted a user outside the docker group" >&2
  exit 1
fi
if PATH="$fixture:$PATH" TEST_RUN_GROUP="$actual_group" SUDO_USER="$actual_user" \
    SYSTEMCTL_TEST_LOG="$fixture/sqlite-rejected.log" SYSTEMCTL_BIN="$fixture/systemctl" \
    SYSTEMD_UNIT_DIR="$fixture/units" SQLITE3_BIN="$fixture/missing-sqlite3" \
      "$timer_installer" >/dev/null 2>&1; then
  echo "FAIL: CoreProtect timer installer accepted a missing sqlite3 command" >&2
  exit 1
fi

: > "$fixture/timer-uninstall.log"
: > "$fixture/maintenance"
PATH="$fixture:$PATH" TEST_RUN_GROUP="$actual_group" \
SYSTEMCTL_TEST_LOG="$fixture/timer-uninstall.log" SYSTEMCTL_BIN="$fixture/systemctl" \
SYSTEMD_UNIT_DIR="$fixture/units" UNIT_TEST_DIR="$fixture/units" \
COREPROTECT_MAINTENANCE_FILE="$fixture/maintenance" \
  "$timer_uninstaller" >/dev/null
if [ -e "$fixture/maintenance" ] ||
    find "$fixture/units" -type f -print -quit | grep -q .; then
  echo "FAIL: CoreProtect timer uninstaller kept unit files after a clean stop" >&2
  exit 1
fi

for unit in \
  mc-coreprotect-db-backup.service \
  mc-coreprotect-db-backup.timer \
  mc-coreprotect-purge.service \
  mc-coreprotect-purge.timer
do
  : > "$fixture/units/$unit"
done
if PATH="$fixture:$PATH" TEST_RUN_GROUP="$actual_group" STOP_FAIL=true \
    UNIT_ACTIVE_STATE=active \
    SYSTEMCTL_TEST_LOG="$fixture/timer-stop-failure.log" SYSTEMCTL_BIN="$fixture/systemctl" \
    SYSTEMD_UNIT_DIR="$fixture/units" UNIT_TEST_DIR="$fixture/units" \
    COREPROTECT_MAINTENANCE_FILE="$fixture/maintenance" \
      "$timer_uninstaller" >/dev/null 2>&1; then
  echo "FAIL: CoreProtect timer uninstaller ignored a service stop failure" >&2
  exit 1
fi
if [ ! -e "$fixture/maintenance" ] ||
    [ ! -e "$fixture/units/mc-coreprotect-db-backup.service" ]; then
  echo "FAIL: failed timer uninstall removed its safety marker or unit files" >&2
  exit 1
fi

rm -f "$fixture/units"/* "$fixture/maintenance"
mkdir -p "$fixture/stopped-states"
: > "$fixture/missing-unit.log"
PATH="$fixture:$PATH" TEST_RUN_GROUP="$actual_group" \
SYSTEMCTL_TEST_LOG="$fixture/missing-unit.log" SYSTEMCTL_BIN="$fixture/systemctl" \
SYSTEMD_UNIT_DIR="$fixture/units" UNIT_TEST_DIR="$fixture/units" \
STOPPED_STATE_DIR="$fixture/stopped-states" \
ACTIVE_WITHOUT_FILE_UNIT=mc-coreprotect-purge.service \
COREPROTECT_MAINTENANCE_FILE="$fixture/maintenance" \
  "$timer_uninstaller" >/dev/null
if ! grep -Fqx 'stop mc-coreprotect-purge.service' "$fixture/missing-unit.log" ||
    [ -e "$fixture/maintenance" ]; then
  echo "FAIL: timer uninstall did not stop a loaded service whose unit file was missing" >&2
  exit 1
fi

: > "$fixture/timer-list-failure.log"
if PATH="$fixture:$PATH" TEST_RUN_GROUP="$actual_group" LIST_FAIL=true \
    SYSTEMCTL_TEST_LOG="$fixture/timer-list-failure.log" SYSTEMCTL_BIN="$fixture/systemctl" \
    SYSTEMD_UNIT_DIR="$fixture/units" UNIT_TEST_DIR="$fixture/units" \
    COREPROTECT_MAINTENANCE_FILE="$fixture/timer-list-failure-maintenance" \
      "$timer_uninstaller" >/dev/null 2>&1; then
  echo "FAIL: CoreProtect timer uninstall ignored list-unit-files failure" >&2
  exit 1
fi
if [ ! -e "$fixture/timer-list-failure-maintenance" ]; then
  echo "FAIL: timer list failure removed the maintenance marker" >&2
  exit 1
fi

echo "OK: systemd safety definitions passed"
