#!/usr/bin/env sh
set -eu

root_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
umask 077
discord_config="${DISCORDSRV_CONFIG_FILE:-$root_dir/minecraft/plugins/DiscordSRV/config.yml}"
discord_linking="${DISCORDSRV_LINKING_FILE:-$root_dir/minecraft/plugins/DiscordSRV/linking.yml}"
discord_messages="${DISCORDSRV_MESSAGES_FILE:-$root_dir/minecraft/plugins/DiscordSRV/messages.yml}"
discord_settings="${DISCORDSRV_ENV_FILE:-$root_dir/.discordsrv.env}"
gate_config="${DISCORD_GUILD_GATE_CONFIG_FILE:-$root_dir/minecraft/plugins/DiscordGuildGate/config.yml}"
gate_jar="${DISCORD_GUILD_GATE_JAR:-$root_dir/minecraft/plugins/DiscordGuildGate.jar}"
tabtps_source="${TABTPS_MANAGED_DIR:-$root_dir/config/managed/TabTPS}"
tabtps_target="${TABTPS_CONFIG_DIR:-$root_dir/minecraft/plugins/TabTPS}"
harden_runner="${HARDEN_SECRET_PERMISSIONS_RUNNER:-$root_dir/scripts/harden-secret-permissions.sh}"

# 途中で設定の反映に失敗しても、既存の認証情報を公開権限のまま残さない
harden_on_exit() {
  "$harden_runner" >/dev/null 2>&1 || true
}
trap harden_on_exit EXIT

require_file() {
  if [ ! -f "$1" ]; then
    echo "ERROR: 必要なファイルがありません: $1" >&2
    echo "       先に Minecraft を一度起動して設定ファイルを生成してください" >&2
    exit 1
  fi
}

copy_config() {
  source_file="$1"
  target_file="$2"
  temporary_file="${target_file}.tmp.$$"

  mkdir -p "$(dirname "$target_file")"
  cp "$source_file" "$temporary_file"
  chmod 0644 "$temporary_file"
  mv "$temporary_file" "$target_file"
}

preflight_runtime_settings() {
  DISCORDSRV_ENV_FILE="$discord_settings" \
  DISCORDSRV_CONFIG_FILE="$discord_config" \
  DISCORDSRV_LINKING_FILE="$discord_linking" \
  DISCORD_GUILD_GATE_CONFIG_FILE="$gate_config" \
  DISCORD_GUILD_GATE_JAR="$gate_jar" \
    "$root_dir/scripts/configure-discordsrv-guilds.sh" --check >/dev/null
  DISCORDSRV_CONFIG_FILE="$discord_config" \
  DISCORDSRV_MESSAGES_FILE="$discord_messages" \
    "$root_dir/scripts/configure-discordsrv-webhooks.sh" --check >/dev/null
  if [ "$(grep -c '^DiscordGameStatus:' "$discord_config")" -ne 1 ] ||
      [ "$(grep -c '^DiscordOnlineStatus:' "$discord_config")" -ne 1 ] ||
      [ "$(grep -c '^StatusUpdateRateInMinutes:' "$discord_config")" -ne 1 ] ||
      [ "$(grep -c '^DiscordChatChannelConsoleCommandEnabled:' "$discord_config")" -ne 1 ] ||
      [ "$(grep -c '^DiscordChatChannelConsoleCommandRolesAllowed:' "$discord_config")" -ne 1 ] ||
      [ "$(grep -c '^MinecraftDiscordAccountLinkedRoleNameToAddUserTo:' "$discord_config")" -ne 1 ] ||
      [ "$(grep -c '^Require linked account to play:' "$discord_linking")" -ne 1 ] ||
      [ "$(grep -c '^[[:space:]]*Not linked message:' "$discord_linking")" -ne 1 ]; then
    echo "ERROR: DiscordSRV の設定形式が管理対象の形式と一致しません" >&2
    return 1
  fi
}

require_file "$discord_config"
require_file "$discord_linking"
require_file "$discord_messages"
require_file "$tabtps_source/main.conf"
require_file "$tabtps_source/display-configs/default.conf"

# 日本語化で設定一式を再生成する前に、後続処理の入力と対応形式を検証する
preflight_runtime_settings

# DiscordSRV 同梱の日本語設定を生成してから、リポジトリの管理対象設定を反映する
DISCORDSRV_CONFIG_FILE="$discord_config" \
  "$root_dir/scripts/configure-discordsrv-language.sh"

# 日本語設定の再生成後にも形式を検査し、部分的な設定反映を避ける
preflight_runtime_settings

# Discord の Guild, Channel と、DiscordSRV 標準の Guild 判定を反映する
DISCORDSRV_ENV_FILE="$discord_settings" \
DISCORDSRV_CONFIG_FILE="$discord_config" \
DISCORDSRV_LINKING_FILE="$discord_linking" \
DISCORD_GUILD_GATE_CONFIG_FILE="$gate_config" \
DISCORD_GUILD_GATE_JAR="$gate_jar" \
  "$root_dir/scripts/configure-discordsrv-guilds.sh"

# Bot のステータスへ接続人数を表示し、Discord と未連携のプレイヤーを拒否する
perl -pi -e 's/^DiscordGameStatus:.*/DiscordGameStatus: ["オンライン｜%online%人接続中"]/' "$discord_config"
perl -pi -e 's/^DiscordOnlineStatus:.*/DiscordOnlineStatus: ONLINE/' "$discord_config"
perl -pi -e 's/^StatusUpdateRateInMinutes:.*/StatusUpdateRateInMinutes: 1/' "$discord_config"
perl -0pi -e 's/^(Require linked account to play:\R[ \t]+Enabled:)[^\r\n]*/$1 true/m' "$discord_linking"
perl -pi -e 's{^(\s*Not linked message:).*$}{$1 "&7参加するには &9Discord &7アカウントとの連携が必要です。\\n\\n&7Discord で &b/link code:{CODE} &7を実行してください。\\n&7連携が完了したら、Minecraftサーバーへ接続し直してください。"}' "$discord_linking"
perl -pi -e 's/^DiscordChatChannelConsoleCommandEnabled:.*/DiscordChatChannelConsoleCommandEnabled: false/' "$discord_config"
perl -pi -e 's/^DiscordChatChannelConsoleCommandRolesAllowed:.*/DiscordChatChannelConsoleCommandRolesAllowed: []/' "$discord_config"

if ! grep -Fqx 'DiscordGameStatus: ["オンライン｜%online%人接続中"]' "$discord_config" ||
    ! grep -Fqx 'DiscordOnlineStatus: ONLINE' "$discord_config" ||
    ! grep -Fqx 'StatusUpdateRateInMinutes: 1' "$discord_config"; then
  echo "ERROR: Discord Bot のステータス表示を反映できませんでした" >&2
  exit 1
fi
if ! perl -0ne 'exit(/^Require linked account to play:\R[ \t]+Enabled:[ \t]*true[ \t]*\R/m ? 0 : 1)' \
    "$discord_linking"; then
  echo "ERROR: DiscordSRV のアカウント連携必須設定を反映できませんでした" >&2
  exit 1
fi
if ! grep -Fqx '  Not linked message: "&7参加するには &9Discord &7アカウントとの連携が必要です。\n\n&7Discord で &b/link code:{CODE} &7を実行してください。\n&7連携が完了したら、Minecraftサーバーへ接続し直してください。"' \
    "$discord_linking"; then
  echo "ERROR: DiscordSRV の初回連携メッセージを反映できませんでした" >&2
  exit 1
fi
if ! grep -q '^DiscordChatChannelConsoleCommandEnabled: false$' "$discord_config"; then
  echo "ERROR: DiscordSRV の console command 無効化を反映できませんでした" >&2
  exit 1
fi
if ! grep -q '^DiscordChatChannelConsoleCommandRolesAllowed: \[\]$' "$discord_config"; then
  echo "ERROR: DiscordSRV の Console Command Role 設定を反映できませんでした" >&2
  exit 1
fi

DISCORDSRV_CONFIG_FILE="$discord_config" \
DISCORDSRV_MESSAGES_FILE="$discord_messages" \
  "$root_dir/scripts/configure-discordsrv-webhooks.sh"

copy_config "$tabtps_source/main.conf" "$tabtps_target/main.conf"
copy_config "$tabtps_source/display-configs/default.conf" "$tabtps_target/display-configs/default.conf"
"$harden_runner"
trap - EXIT

echo "OK: DiscordSRV と TabTPS の管理対象設定を反映しました"
