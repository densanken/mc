#!/usr/bin/env sh
set -eu

RCON_HOST="${RCON_HOST:-minecraft}"
RCON_PORT="${RCON_PORT:-25575}"
RCON_PASSWORD_FILE="${RCON_PASSWORD_FILE:-/run/secrets/rcon_password}"
MAX_ATTEMPTS="${PUBLIC_READINESS_ATTEMPTS:-12}"
RETRY_SECONDS="${PUBLIC_READINESS_RETRY_SECONDS:-5}"
ANSI_ESCAPE="$(printf '\033')"

normalize_rcon_response() {
  printf '%s' "$1" |
    sed "s/${ANSI_ESCAPE}\\[[0-9;]*m//g" |
    tr -d '\r\n'
}

if [ ! -r "$RCON_PASSWORD_FILE" ]; then
  echo "ERROR: RCON password file is not readable: $RCON_PASSWORD_FILE" >&2
  exit 2
fi
RCON_PASSWORD="$(tr -d '\r\n' < "$RCON_PASSWORD_FILE")"
if [ -z "$RCON_PASSWORD" ]; then
  echo "ERROR: RCON password file is empty: $RCON_PASSWORD_FILE" >&2
  exit 2
fi
export RCON_PASSWORD

case "$MAX_ATTEMPTS" in
  '' | *[!0-9]*)
    echo "ERROR: readiness retry settings must be positive integers" >&2
    exit 2
    ;;
esac
case "$MAX_ATTEMPTS" in
  *[1-9]*) ;;
  *)
    echo "ERROR: readiness retry settings must be positive integers" >&2
    exit 2
    ;;
esac
case "$RETRY_SECONDS" in
  '' | *[!0-9]*)
    echo "ERROR: readiness retry settings must be positive integers" >&2
    exit 2
    ;;
esac
case "$RETRY_SECONDS" in
  *[1-9]*) ;;
  *)
    echo "ERROR: readiness retry settings must be positive integers" >&2
    exit 2
    ;;
esac

attempt=1
while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
  status="$(rcon-cli --host "$RCON_HOST" --port "$RCON_PORT" discordguildgate status 2>/dev/null || true)"
  status="$(normalize_rcon_response "$status")"
  plugin_health="$(rcon-cli --host "$RCON_HOST" --port "$RCON_PORT" discordguildgate plugins 2>/dev/null || true)"
  plugin_health="$(normalize_rcon_response "$plugin_health")"
  # DiscordGuildGate は全必須プラグインが有効な場合だけ ENABLED を返す
  if printf '%s\n' "$status" | grep -Eq '^READY allowed-guilds=[1-9][0-9]*$'; then
    if printf '%s\n' "$plugin_health" | grep -Eq '^ENABLED required-plugins=[1-9][0-9]*$'; then
      echo "OK: Discord access gate is ready ($status, $plugin_health)"
      exit 0
    fi
  fi

  echo "WAIT: public readiness failed (gate=${status:-no response}, plugins=${plugin_health:-no response}), attempt $attempt/$MAX_ATTEMPTS" >&2
  if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
    sleep "$RETRY_SECONDS"
  fi
  attempt=$((attempt + 1))
done

echo "ERROR: refusing to start the public tunnel because the access gate or required plugins are not ready" >&2
exit 1
