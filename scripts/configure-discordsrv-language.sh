#!/usr/bin/env sh
set -eu

root_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
discord_config="${DISCORDSRV_CONFIG_FILE:-$root_dir/minecraft/plugins/DiscordSRV/config.yml}"

if [ ! -f "$discord_config" ]; then
  echo "ERROR: 必要なファイルがありません: $discord_config" >&2
  echo "       先に Minecraft を一度起動して設定ファイルを生成してください" >&2
  exit 1
fi

read_language() {
  awk -F: '
    /^ForcedLanguage:/ {
      value = substr($0, index($0, ":") + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      first = substr(value, 1, 1)
      last = substr(value, length(value), 1)
      if ((first == "\"" && last == "\"") ||
          (first == "\047" && last == "\047")) {
        value = substr(value, 2, length(value) - 2)
      } else if (first == "\"" || first == "\047" ||
                 last == "\"" || last == "\047") {
        exit
      }
      print tolower(value)
      exit
    }
  ' "$discord_config"
}

current_language="$(read_language || true)"

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

case "$(read_language || true)" in
  ja|japanese) ;;
  *)
    echo "ERROR: DiscordSRV の日本語設定を確認できませんでした" >&2
    exit 1
    ;;
esac

echo "OK: DiscordSRV の表示言語を日本語へ変更しました"
