#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"

bash -n "$root_dir"/scripts/*.sh "$root_dir"/tests/*.sh
for script in "$root_dir"/scripts/*.sh "$root_dir"/tests/*.sh; do
  case "$(head -n 1 "$script")" in
    '#!/bin/sh' | '#!/usr/bin/env sh') sh -n "$script" ;;
  esac
done
"$root_dir/tests/test-verify-jars.sh"
"$root_dir/tests/test-public-readiness.sh"
"$root_dir/tests/test-check-status.sh"
"$root_dir/tests/test-coreprotect-backup.sh"
"$root_dir/tests/test-coreprotect-purge.sh"
"$root_dir/tests/test-systemd-safety.sh"
"$root_dir/tests/test-configure-discordsrv-guilds.sh"
"$root_dir/tests/test-configure-discordsrv-language.sh"
"$root_dir/tests/test-configure-discordsrv-webhooks.sh"
"$root_dir/tests/test-configure-runtime-settings.sh"
"$root_dir/tests/test-update-advancement-translations.sh"
"$root_dir/tests/test-update-image-digests.sh"
"$root_dir/tests/test-tabtps-managed-config.sh"
"$root_dir/tests/test-start-minecraft.sh"
"$root_dir/tests/test-verify-backups.sh"
"$root_dir/tests/test-backup-storage.sh"
"$root_dir/tests/test-backup-storage-probe.sh"

export BACKUP_ROOT="${TMPDIR:-/tmp}/mc-compose-backups-$$"
compose_config="$(docker compose --env-file "$root_dir/.env.example" config)"
if ! grep -Fq "source: $BACKUP_ROOT/world" <<<"$compose_config" ||
    ! grep -Fq 'target: /backups' <<<"$compose_config" ||
    grep -Fq "source: $root_dir/backups" <<<"$compose_config"; then
  echo "FAIL: backups service does not use the external BACKUP_ROOT" >&2
  exit 1
fi
if docker compose --env-file "$root_dir/.env.example" config --services | grep -qx playit; then
  echo "FAIL: service-less compose up must not include playit" >&2
  exit 1
fi
if ! docker compose --env-file "$root_dir/.env.example" config --profiles | grep -qx public; then
  echo "FAIL: playit public profile is missing" >&2
  exit 1
fi
playit_restart="$(
  docker compose --env-file "$root_dir/.env.example" --profile public config |
    awk '
      $0 == "  playit:" { in_playit = 1; next }
      in_playit && /^  [^ ]/ { exit }
      in_playit && /^    restart:/ { print $2; exit }
    '
)"
if [ "$playit_restart" != "unless-stopped" ]; then
  echo "FAIL: playit must restart after Docker daemon recovery" >&2
  exit 1
fi
backups_on_startup="$(
  docker compose --env-file "$root_dir/.env.example" config |
    awk '
      $0 == "  backups:" { in_backups = 1; next }
      in_backups && /^  [^ ]/ { exit }
      in_backups && /^      BACKUP_ON_STARTUP:/ { print $2; exit }
    '
)"
if [ "$backups_on_startup" != "\"false\"" ] && [ "$backups_on_startup" != "false" ]; then
  echo "FAIL: backups must wait for an explicit initial backup" >&2
  exit 1
fi
# The dollars belong to the rendered Compose command and must stay literal here.
# shellcheck disable=SC2016
if ! grep -Fq '[ "$${ONE_SHOT:-true}" = false ] || exit "$$1"' <<<"$compose_config"; then
  echo "FAIL: one-shot backups do not propagate the upstream backup status" >&2
  exit 1
fi
backups_restart="$(
  docker compose --env-file "$root_dir/.env.example" config |
    awk '
      $0 == "  backups:" { in_backups = 1; next }
      in_backups && /^  [^ ]/ { exit }
      in_backups && /^    restart:/ { print $2; exit }
    '
)"
if [ "$backups_restart" != "unless-stopped" ]; then
  echo "FAIL: backups must restart after Docker daemon recovery" >&2
  exit 1
fi
if ! grep -Fq '/opt/mc/check-backup-storage.sh' <<<"$compose_config"; then
  echo "FAIL: backups healthcheck does not probe external storage" >&2
  exit 1
fi
unset BACKUP_ROOT backups_restart compose_config
echo "OK: all local tests passed"
