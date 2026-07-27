#!/usr/bin/env sh
set -eu

root_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
discord_config="${DISCORDSRV_CONFIG_FILE:-$root_dir/minecraft/plugins/DiscordSRV/config.yml}"

if [ ! -f "$discord_config" ]; then
  echo "ERROR: 必要なファイルがありません: $discord_config" >&2
  echo "       先に Minecraft を一度起動して設定ファイルを生成してください" >&2
  exit 1
fi

current_language="$({
  awk -F: '
    /^ForcedLanguage:/ {
      value = substr($0, index($0, ":") + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      gsub(/^["\047]|["\047]$/, "", value)
      print tolower(value)
      exit
    }
  ' "$discord_config"
} || true)"

case "$current_language" in
  ja|japanese)
    echo "OK: DiscordSRV の表示言語は日本語です"
    exit 0
    ;;
esac

if [ -n "${DISCORDSRV_LANGUAGE_RUNNER:-}" ]; then
  "$DISCORDSRV_LANGUAGE_RUNNER" "$discord_config"
elif ! docker compose --project-directory "$root_dir" exec -T minecraft \
    rcon-cli -- discordsrv language Japanese -confirm; then
  echo "ERROR: DiscordSRV の表示言語を日本語へ変更できませんでした" >&2
  echo "       docker compose ps と docker compose logs --tail=160 minecraft で状態を確認してから再実行してください" >&2
  exit 1
fi

if ! grep -Eq '^ForcedLanguage:[[:space:]]*(JA|Japanese)[[:space:]]*$' "$discord_config"; then
  echo "ERROR: DiscordSRV の日本語設定を確認できませんでした" >&2
  exit 1
fi

echo "OK: DiscordSRV の表示言語を日本語へ変更しました"
