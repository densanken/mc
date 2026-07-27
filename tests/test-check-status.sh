#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

cat > "$fixture/docker" <<'DOCKER'
#!/usr/bin/env sh
set -eu
printf '%s\n' "$*" >> "$DOCKER_TEST_LOG"
case "$*" in
  'compose ps --status running --quiet minecraft')
    [ "${MINECRAFT_RUNNING:-true}" != true ] || printf 'minecraft-container\n'
    ;;
  "inspect --format {{.State.Health.Status}} minecraft-container")
    printf '%s\n' "${MINECRAFT_HEALTH:-healthy}"
    ;;
  'compose ps --status running --quiet backups')
    [ "${BACKUPS_RUNNING:-true}" != true ] || printf 'backups-container\n'
    ;;
  "inspect --format {{.State.Health.Status}} backups-container")
    printf '%s\n' "${BACKUPS_HEALTH:-healthy}"
    ;;
  'compose ps --status running --quiet playit')
    [ "${PLAYIT_RUNNING:-false}" != true ] || printf 'playit-container\n'
    ;;
  'compose exec -T minecraft rcon-cli discordguildgate status')
    printf '%s\n' "${GATE_STATUS:-READY allowed-guilds=1}"
    ;;
  'compose exec -T minecraft rcon-cli discordguildgate plugins')
    printf '%s\n' "${PLUGIN_HEALTH:-ENABLED required-plugins=8}"
    ;;
esac
DOCKER
cat > "$fixture/systemctl" <<'SYSTEMCTL'
#!/usr/bin/env sh
set -eu
case "${1:-}" in
  is-active) [ "${INACTIVE_UNIT:-}" != "${3:-}" ] ;;
  is-failed) [ "${FAILED_UNIT:-}" = "${3:-}" ] ;;
  *) exit 1 ;;
esac
SYSTEMCTL
cat > "$fixture/verify-backups" <<'VERIFY'
#!/usr/bin/env sh
exit "${BACKUPS_VERIFY_EXIT_CODE:-0}"
VERIFY
chmod 0755 "$fixture/docker" "$fixture/systemctl" "$fixture/verify-backups"
mkdir -p "$fixture/coreprotect"
: > "$fixture/coreprotect/coreprotect-recent.db.gz"
export COREPROTECT_BACKUP_DIR="$fixture/coreprotect"

DOCKER_TEST_LOG="$fixture/success.log" DOCKER_BIN="$fixture/docker" \
SYSTEMCTL_BIN="$fixture/systemctl" VERIFY_BACKUPS_RUNNER="$fixture/verify-backups" \
  "$root_dir/scripts/check-status.sh" >/dev/null

ansi_gate_status="$(printf 'READY allowed-guilds=1\n\033[0m')"
ansi_plugin_health="$(printf 'ENABLED required-plugins=8\n\033[0m')"
DOCKER_TEST_LOG="$fixture/ansi.log" DOCKER_BIN="$fixture/docker" \
SYSTEMCTL_BIN="$fixture/systemctl" VERIFY_BACKUPS_RUNNER="$fixture/verify-backups" \
PLAYIT_RUNNING=true GATE_STATUS="$ansi_gate_status" \
PLUGIN_HEALTH="$ansi_plugin_health" \
  "$root_dir/scripts/check-status.sh" >/dev/null

if DOCKER_TEST_LOG="$fixture/plugin-disabled.log" DOCKER_BIN="$fixture/docker" \
    SYSTEMCTL_BIN="$fixture/systemctl" VERIFY_BACKUPS_RUNNER="$fixture/verify-backups" \
    PLUGIN_HEALTH='DISABLED required-plugins=CoreProtect' \
    "$root_dir/scripts/check-status.sh" >/dev/null 2>&1; then
  echo "FAIL: check-status accepted a disabled required plugin" >&2
  exit 1
fi

if DOCKER_TEST_LOG="$fixture/plugin-empty.log" DOCKER_BIN="$fixture/docker" \
    SYSTEMCTL_BIN="$fixture/systemctl" VERIFY_BACKUPS_RUNNER="$fixture/verify-backups" \
    PLUGIN_HEALTH='ENABLED required-plugins=0' \
    "$root_dir/scripts/check-status.sh" >/dev/null 2>&1; then
  echo "FAIL: check-status accepted an empty required plugin list" >&2
  exit 1
fi

if DOCKER_TEST_LOG="$fixture/gate-not-ready.log" DOCKER_BIN="$fixture/docker" \
    SYSTEMCTL_BIN="$fixture/systemctl" VERIFY_BACKUPS_RUNNER="$fixture/verify-backups" \
    PLAYIT_RUNNING=true GATE_STATUS='NOT_READY discordsrv-not-ready' \
    "$root_dir/scripts/check-status.sh" >/dev/null 2>&1; then
  echo "FAIL: check-status accepted a running tunnel with a non-ready gate" >&2
  exit 1
fi

DOCKER_TEST_LOG="$fixture/private.log" DOCKER_BIN="$fixture/docker" \
SYSTEMCTL_BIN="$fixture/systemctl" VERIFY_BACKUPS_RUNNER="$fixture/verify-backups" \
PLAYIT_RUNNING=false \
  "$root_dir/scripts/check-status.sh" >/dev/null

if DOCKER_TEST_LOG="$fixture/unhealthy.log" DOCKER_BIN="$fixture/docker" \
    SYSTEMCTL_BIN="$fixture/systemctl" VERIFY_BACKUPS_RUNNER="$fixture/verify-backups" \
    MINECRAFT_HEALTH=unhealthy "$root_dir/scripts/check-status.sh" >/dev/null 2>&1; then
  echo "FAIL: check-status accepted unhealthy minecraft" >&2
  exit 1
fi

if DOCKER_TEST_LOG="$fixture/backups-unhealthy.log" DOCKER_BIN="$fixture/docker" \
    SYSTEMCTL_BIN="$fixture/systemctl" VERIFY_BACKUPS_RUNNER="$fixture/verify-backups" \
    BACKUPS_HEALTH=unhealthy \
    "$root_dir/scripts/check-status.sh" >/dev/null 2>&1; then
  echo "FAIL: check-status accepted unhealthy backup storage" >&2
  exit 1
fi

for inactive_unit in \
  mc-coreprotect-db-backup.timer \
  mc-coreprotect-purge.timer
do
  if DOCKER_TEST_LOG="$fixture/unit.log" DOCKER_BIN="$fixture/docker" \
      SYSTEMCTL_BIN="$fixture/systemctl" VERIFY_BACKUPS_RUNNER="$fixture/verify-backups" \
      INACTIVE_UNIT="$inactive_unit" \
      "$root_dir/scripts/check-status.sh" >/dev/null 2>&1; then
    echo "FAIL: check-status accepted inactive unit: $inactive_unit" >&2
    exit 1
  fi
done

for failed_unit in \
  mc-coreprotect-db-backup.service \
  mc-coreprotect-purge.service
do
  if DOCKER_TEST_LOG="$fixture/service.log" DOCKER_BIN="$fixture/docker" \
      SYSTEMCTL_BIN="$fixture/systemctl" VERIFY_BACKUPS_RUNNER="$fixture/verify-backups" \
      FAILED_UNIT="$failed_unit" \
      "$root_dir/scripts/check-status.sh" >/dev/null 2>&1; then
    echo "FAIL: check-status accepted failed service: $failed_unit" >&2
    exit 1
  fi
done

mkdir -p "$fixture/stale-coreprotect"
: > "$fixture/stale-coreprotect/coreprotect-stale.db.gz"
touch -t 200001010000 "$fixture/stale-coreprotect/coreprotect-stale.db.gz"
if DOCKER_TEST_LOG="$fixture/stale.log" DOCKER_BIN="$fixture/docker" \
    SYSTEMCTL_BIN="$fixture/systemctl" VERIFY_BACKUPS_RUNNER="$fixture/verify-backups" \
    COREPROTECT_BACKUP_DIR="$fixture/stale-coreprotect" \
    "$root_dir/scripts/check-status.sh" >/dev/null 2>&1; then
  echo "FAIL: check-status accepted stale CoreProtect backups" >&2
  exit 1
fi

if DOCKER_TEST_LOG="$fixture/backup-failure.log" DOCKER_BIN="$fixture/docker" \
    SYSTEMCTL_BIN="$fixture/systemctl" VERIFY_BACKUPS_RUNNER="$fixture/verify-backups" \
    BACKUPS_VERIFY_EXIT_CODE=1 PLAYIT_RUNNING=true GATE_STATUS='NOT_READY discordsrv-not-ready' \
    "$root_dir/scripts/check-status.sh" >/dev/null 2>&1; then
  echo "FAIL: check-status accepted failed backup and Gate checks" >&2
  exit 1
fi
if ! grep -q 'discordguildgate status' "$fixture/backup-failure.log"; then
  echo "FAIL: Gate was not checked before reporting backup failure" >&2
  exit 1
fi

: > "$fixture/coreprotect-maintenance"
if DOCKER_TEST_LOG="$fixture/maintenance.log" DOCKER_BIN="$fixture/docker" \
    SYSTEMCTL_BIN="$fixture/systemctl" VERIFY_BACKUPS_RUNNER="$fixture/verify-backups" \
    COREPROTECT_MAINTENANCE_FILE="$fixture/coreprotect-maintenance" \
    "$root_dir/scripts/check-status.sh" >/dev/null 2>&1; then
  echo "FAIL: check-status accepted paused CoreProtect jobs" >&2
  exit 1
fi

echo "OK: status check fixtures passed"
