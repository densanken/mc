#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

config="$fixture/config.yml"
messages="$fixture/messages.yml"

cat > "$config" <<'CONFIG'
Experiment_WebhookChatMessageDelivery: false
Experiment_WebhookChatMessageUsernameFormat: "%displayname%"
Experiment_WebhookChatMessageFormat: "%message%"
Experiment_WebhookChatMessageUsernameFromDiscord: false
Experiment_WebhookChatMessageAvatarFromDiscord: false
CONFIG

cat > "$messages" <<'MESSAGES'
DiscordToMinecraftChatMessageFormat: "[<aqua>Discord</aqua> | %toprolecolor%%toprolealias%<reset>] %name%%reply% » %message%"
DiscordToMinecraftChatMessageFormatNoRole: "[<aqua>Discord</aqua>] %name%%reply% » %message%"
MESSAGES

for section in \
  MinecraftPlayerJoinMessage \
  MinecraftPlayerFirstJoinMessage \
  MinecraftPlayerLeaveMessage \
  MinecraftPlayerDeathMessage \
  MinecraftPlayerAchievementMessage
do
  cat >> "$messages" <<MESSAGES
$section:
  Enabled: true
  Webhook:
    Enable: false
    AvatarUrl: "%botavatarurl%"
    Name: "%botname%"
  Content: ""
  Embed:
    Enabled: true
    Color: "#ffffff"

MESSAGES
done

cat >> "$messages" <<'MESSAGES'
DiscordAccountLinked: "Your Discord account has been linked to %name% (%uuid%)"
DiscordAccountAlreadyLinked: "You are already linked to %username% (%uuid%)"
MESSAGES

config_before_check="$(cat "$config")"
messages_before_check="$(cat "$messages")"
DISCORDSRV_CONFIG_FILE="$config" \
DISCORDSRV_MESSAGES_FILE="$messages" \
  "$root_dir/scripts/configure-discordsrv-webhooks.sh" --check >/dev/null
if [ "$(cat "$config")" != "$config_before_check" ] ||
    [ "$(cat "$messages")" != "$messages_before_check" ]; then
  echo "FAIL: --check changed DiscordSRV Webhook configuration" >&2
  exit 1
fi

DISCORDSRV_CONFIG_FILE="$config" \
DISCORDSRV_MESSAGES_FILE="$messages" \
  "$root_dir/scripts/configure-discordsrv-webhooks.sh" >/dev/null

grep -q '^Experiment_WebhookChatMessageDelivery: true$' "$config"
grep -q '^Experiment_WebhookChatMessageUsernameFromDiscord: false$' "$config"
grep -Fqx 'DiscordToMinecraftChatMessageFormat: "[<aqua>Discord</aqua>] %name%%reply% » %message%"' "$messages"
grep -Fqx 'DiscordToMinecraftChatMessageFormatNoRole: "[<aqua>Discord</aqua>] %name%%reply% » %message%"' "$messages"
if grep -Eq '%toprole|%allroles' "$messages"; then
  echo "FAIL: Discord to Minecraft chat format still contains a role placeholder" >&2
  exit 1
fi
[ "$(grep -c '^    Enable: true$' "$messages")" = 5 ]
[ "$(grep -c '^  Enabled: true$' "$messages")" = 2 ]
[ "$(grep -c '^  Enabled: false$' "$messages")" = 3 ]
[ "$(grep -c '^    AvatarUrl: ""$' "$messages")" = 5 ]
[ "$(grep -c '^    Name: "%username%"$' "$messages")" = 5 ]
[ "$(grep -c '^    Enabled: false$' "$messages")" = 5 ]
grep -q '^  Content: "サーバーに参加しました"$' "$messages"
grep -q '^  Content: "%deathmessage%"$' "$messages"
grep -q '^  Content: "進捗「%achievement%」を達成しました"$' "$messages"
grep -q '^DiscordAccountLinked: "Minecraftアカウント（%name%）との連携が完了しました。Minecraftサーバーへ接続し直してください。"$' "$messages"
grep -q '^DiscordAccountAlreadyLinked: "すでにMinecraftアカウント（%username%）と連携されています。Minecraftサーバーへ接続し直してください。"$' "$messages"
if [ "$(stat -c '%a' "$config" 2>/dev/null || stat -f '%Lp' "$config")" != 600 ]; then
  echo "FAIL: DiscordSRV config.yml mode is not 0600" >&2
  exit 1
fi

DISCORDSRV_CONFIG_FILE="$config" \
DISCORDSRV_MESSAGES_FILE="$messages" \
  "$root_dir/scripts/configure-discordsrv-webhooks.sh" >/dev/null

[ "$(grep -c '^    Enable: true$' "$messages")" = 5 ]
[ "$(grep -c '^  Enabled: true$' "$messages")" = 2 ]

printf 'OK: configure-discordsrv-webhooks tests passed\n'
