#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

cat > "$fixture/rcon-cli" <<'EOF'
#!/usr/bin/env sh
case "$*" in
  *'discordguildgate status')
    printf '%s\n' "${RCON_TEST_RESPONSE:-}"
    ;;
  *'discordguildgate plugins')
    printf '%s\n' "${PLUGIN_TEST_RESPONSE:-ENABLED required-plugins=8}"
    ;;
esac
EOF
chmod 0755 "$fixture/rcon-cli"
printf 'test-password\n' > "$fixture/rcon-password"

PATH="$fixture:$PATH" RCON_TEST_RESPONSE='READY allowed-guilds=2' \
  RCON_PASSWORD_FILE="$fixture/rcon-password" PUBLIC_READINESS_ATTEMPTS=1 \
  "$root_dir/scripts/check-public-readiness.sh" >/dev/null

crlf_response="$(printf 'READY allowed-guilds=2\r')"
output="$(PATH="$fixture:$PATH" RCON_TEST_RESPONSE="$crlf_response" \
  RCON_PASSWORD_FILE="$fixture/rcon-password" PUBLIC_READINESS_ATTEMPTS=1 \
  "$root_dir/scripts/check-public-readiness.sh")"
if [ "$output" != \
    'OK: Discord access gate is ready (READY allowed-guilds=2, ENABLED required-plugins=8)' ]; then
  echo "FAIL: CRLF response was not normalized" >&2
  exit 1
fi

ansi_status="$(printf 'READY allowed-guilds=2\n\033[0m')"
ansi_plugins="$(printf 'ENABLED required-plugins=8\n\033[0m')"
output="$(PATH="$fixture:$PATH" RCON_TEST_RESPONSE="$ansi_status" \
  PLUGIN_TEST_RESPONSE="$ansi_plugins" \
  RCON_PASSWORD_FILE="$fixture/rcon-password" PUBLIC_READINESS_ATTEMPTS=1 \
  "$root_dir/scripts/check-public-readiness.sh")"
if [ "$output" != \
    'OK: Discord access gate is ready (READY allowed-guilds=2, ENABLED required-plugins=8)' ]; then
  echo "FAIL: ANSI reset sequence was not normalized" >&2
  exit 1
fi

for invalid_plugin_health in \
  'DISABLED required-plugins=CoreProtect' \
  'ENABLED' \
  'ENABLED required-plugins=' \
  'ENABLED required-plugins=0'
do
  if PATH="$fixture:$PATH" RCON_TEST_RESPONSE='READY allowed-guilds=2' \
      PLUGIN_TEST_RESPONSE="$invalid_plugin_health" \
      RCON_PASSWORD_FILE="$fixture/rcon-password" PUBLIC_READINESS_ATTEMPTS=1 \
      "$root_dir/scripts/check-public-readiness.sh" >/dev/null 2>&1; then
    echo "FAIL: invalid plugin health was accepted: $invalid_plugin_health" >&2
    exit 1
  fi
done

if PATH="$fixture:$PATH" RCON_TEST_RESPONSE='NOT_READY discordsrv-not-ready' \
    RCON_PASSWORD_FILE="$fixture/rcon-password" PUBLIC_READINESS_ATTEMPTS=1 \
    "$root_dir/scripts/check-public-readiness.sh" >/dev/null 2>&1; then
  echo "FAIL: NOT_READY response was accepted" >&2
  exit 1
fi

for invalid_ready in \
  'READY' \
  'READY allowed-guilds=0' \
  'READYMALFORMED' \
  'READY allowed-guilds=1 unexpected'
do
  if PATH="$fixture:$PATH" RCON_TEST_RESPONSE="$invalid_ready" \
      RCON_PASSWORD_FILE="$fixture/rcon-password" PUBLIC_READINESS_ATTEMPTS=1 \
      "$root_dir/scripts/check-public-readiness.sh" >/dev/null 2>&1; then
    echo "FAIL: malformed READY response was accepted: $invalid_ready" >&2
    exit 1
  fi
done

if PATH="$fixture:$PATH" RCON_TEST_RESPONSE='' \
    RCON_PASSWORD_FILE="$fixture/rcon-password" PUBLIC_READINESS_ATTEMPTS=1 \
    "$root_dir/scripts/check-public-readiness.sh" >/dev/null 2>&1; then
  echo "FAIL: empty RCON response was accepted" >&2
  exit 1
fi

echo "OK: public readiness fixtures passed"
