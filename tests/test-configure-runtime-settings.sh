#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

config="$fixture/DiscordSRV/config.yml"
linking="$fixture/DiscordSRV/linking.yml"
messages="$fixture/DiscordSRV/messages.yml"
settings="$fixture/discordsrv.env"
gate_config="$fixture/DiscordGuildGate/config.yml"
gate_jar="$fixture/DiscordGuildGate.jar"
tabtps_source="$fixture/managed/TabTPS"
tabtps_target="$fixture/runtime/TabTPS"
language_runner="$fixture/set-language"
harden_runner="$fixture/harden"
language_log="$fixture/language.log"

mkdir -p "$(dirname "$config")" "$tabtps_source/display-configs"
cat > "$config" <<'CONFIG'
Channels: {"global": "00000000000000000"}
MinecraftDiscordAccountLinkedRoleNameToAddUserTo: "Linked"
Experiment_WebhookChatMessageDelivery: false
Experiment_WebhookChatMessageUsernameFormat: "%displayname%"
Experiment_WebhookChatMessageFormat: "%message%"
Experiment_WebhookChatMessageUsernameFromDiscord: false
Experiment_WebhookChatMessageAvatarFromDiscord: false
ForcedLanguage: none
DiscordGameStatus: ["playing Minecraft"]
DiscordOnlineStatus: ONLINE
StatusUpdateRateInMinutes: 2
DiscordChatChannelConsoleCommandEnabled: true
DiscordChatChannelConsoleCommandRolesAllowed: ["Admin"]
CONFIG
cat > "$linking" <<'LINKING'
Require linked account to play:
  Enabled: false
  Not linked message: "Discord Invite » {INVITE}"
  Must be in Discord server: false
  Subscriber role:
    Require subscriber role to join: false
    Subscriber roles: []
    Require all of the listed roles: false
LINKING
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

MESSAGES
done
cat >> "$messages" <<'MESSAGES'
DiscordAccountLinked: "Your Discord account has been linked to %name% (%uuid%)"
DiscordAccountAlreadyLinked: "You are already linked to %username% (%uuid%)"
MESSAGES
cat > "$settings" <<'SETTINGS'
DISCORD_REQUIRED_GUILD_IDS=12345678901234567
DISCORD_CHAT_CHANNEL_ID=34567890123456789
DISCORD_LINKED_ROLE_ID=45678901234567890
DISCORD_REQUIRED_ROLE_IDS=
DISCORD_REQUIRE_ALL_ROLES=false
SETTINGS
printf 'fixture\n' > "$gate_jar"
printf 'main\n' > "$tabtps_source/main.conf"
printf 'display\n' > "$tabtps_source/display-configs/default.conf"

cat > "$language_runner" <<'RUNNER'
#!/usr/bin/env sh
set -eu
printf 'called\n' >> "$DISCORDSRV_LANGUAGE_RUNNER_LOG"
perl -pi -e 's/^ForcedLanguage:.*/ForcedLanguage: Japanese/' "$1"
RUNNER
cat > "$harden_runner" <<'HARDEN'
#!/usr/bin/env sh
set -eu
printf 'called\n' >> "$HARDEN_TEST_LOG"
HARDEN
chmod 0755 "$language_runner" "$harden_runner"

DISCORDSRV_CONFIG_FILE="$config" \
DISCORDSRV_LINKING_FILE="$linking" \
DISCORDSRV_MESSAGES_FILE="$messages" \
DISCORDSRV_ENV_FILE="$settings" \
DISCORD_GUILD_GATE_CONFIG_FILE="$gate_config" \
DISCORD_GUILD_GATE_JAR="$gate_jar" \
TABTPS_MANAGED_DIR="$tabtps_source" \
TABTPS_CONFIG_DIR="$tabtps_target" \
DISCORDSRV_LANGUAGE_RUNNER="$language_runner" \
DISCORDSRV_LANGUAGE_RUNNER_LOG="$language_log" \
HARDEN_SECRET_PERMISSIONS_RUNNER="$harden_runner" \
HARDEN_TEST_LOG="$fixture/harden.log" \
  "$root_dir/scripts/configure-runtime-settings.sh" >/dev/null

grep -q '^ForcedLanguage: Japanese$' "$config"
grep -Fqx 'DiscordGameStatus: ["オンライン｜%online%人接続中"]' "$config"
grep -Fqx 'DiscordOnlineStatus: ONLINE' "$config"
grep -Fqx 'StatusUpdateRateInMinutes: 1' "$config"
grep -q '^DiscordChatChannelConsoleCommandEnabled: false$' "$config"
grep -Fqx 'MinecraftDiscordAccountLinkedRoleNameToAddUserTo: "45678901234567890"' "$config"
grep -q '^Experiment_WebhookChatMessageUsernameFromDiscord: false$' "$config"
grep -q '^  Enabled: true$' "$linking"
grep -Fqx '  Not linked message: "&7参加するには &9Discord &7アカウントとの連携が必要です。\n\n&7Discord で &b/link code:{CODE} &7を実行してください。\n&7連携が完了したら、Minecraftサーバーへ接続し直してください。"' "$linking"
if grep -Eq 'changethisintheconfig|\{INVITE\}' "$linking"; then
  echo "FAIL: invite link remains in the initial account-link message" >&2
  exit 1
fi
grep -q '^  - "12345678901234567"$' "$gate_config"
grep -q '^    Enable: true$' "$messages"
[ "$(grep -c '^  Enabled: true$' "$messages")" = 2 ]
[ "$(grep -c '^  Enabled: false$' "$messages")" = 3 ]
grep -Fqx 'DiscordToMinecraftChatMessageFormat: "[<aqua>Discord</aqua>] %name%%reply% » %message%"' "$messages"
grep -Fqx 'DiscordToMinecraftChatMessageFormatNoRole: "[<aqua>Discord</aqua>] %name%%reply% » %message%"' "$messages"
cmp "$tabtps_source/main.conf" "$tabtps_target/main.conf"
cmp "$tabtps_source/display-configs/default.conf" "$tabtps_target/display-configs/default.conf"
[ "$(wc -l < "$language_log" | tr -d ' ')" = 1 ]
if [ "$(wc -l < "$fixture/harden.log" | tr -d ' ')" -ne 1 ]; then
  echo "FAIL: secret permissions were not hardened exactly once after success" >&2
  exit 1
fi

perl -pi -e 's/^ForcedLanguage:.*/ForcedLanguage: none/' "$config"
perl -pi -e 's/^DISCORD_REQUIRED_GUILD_IDS=.*/DISCORD_REQUIRED_GUILD_IDS=invalid/' "$settings"
rm -f "$language_log"
if DISCORDSRV_CONFIG_FILE="$config" \
    DISCORDSRV_LINKING_FILE="$linking" \
    DISCORDSRV_MESSAGES_FILE="$messages" \
    DISCORDSRV_ENV_FILE="$settings" \
    DISCORD_GUILD_GATE_CONFIG_FILE="$gate_config" \
    DISCORD_GUILD_GATE_JAR="$gate_jar" \
    TABTPS_MANAGED_DIR="$tabtps_source" \
    TABTPS_CONFIG_DIR="$tabtps_target" \
    DISCORDSRV_LANGUAGE_RUNNER="$language_runner" \
    DISCORDSRV_LANGUAGE_RUNNER_LOG="$language_log" \
    HARDEN_SECRET_PERMISSIONS_RUNNER="$harden_runner" \
    HARDEN_TEST_LOG="$fixture/harden.log" \
    "$root_dir/scripts/configure-runtime-settings.sh" >/dev/null 2>&1; then
  echo "FAIL: invalid Discord settings were accepted" >&2
  exit 1
fi
if [ -e "$language_log" ] || ! grep -q '^ForcedLanguage: none$' "$config"; then
  echo "FAIL: language settings changed before preflight completed" >&2
  exit 1
fi
if [ "$(wc -l < "$fixture/harden.log" | tr -d ' ')" -ne 2 ]; then
  echo "FAIL: secret permissions were not hardened after a failed preflight" >&2
  exit 1
fi

echo "OK: runtime configuration fixtures passed"
