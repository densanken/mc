#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

settings="$fixture/discordsrv.env"
discord_config="$fixture/config.yml"
linking="$fixture/linking.yml"
gate_config="$fixture/DiscordGuildGate/config.yml"
gate_jar="$fixture/DiscordGuildGate.jar"

printf '%s\n' \
  'DISCORD_REQUIRED_GUILD_IDS=12345678901234567,23456789012345678' \
  'DISCORD_CHAT_CHANNEL_ID=34567890123456789' \
  'DISCORD_LINKED_ROLE_ID=67890123456789012' \
  'DISCORD_REQUIRED_ROLE_IDS=45678901234567890,56789012345678901' \
  'DISCORD_REQUIRE_ALL_ROLES=false' > "$settings"
printf '%s\n' \
  'Channels: {"global": "00000000000000000"}' \
  'MinecraftDiscordAccountLinkedRoleNameToAddUserTo: "Linked"' > "$discord_config"
printf '%s\n' \
  'Require linked account to play:' \
  '  Enabled: true' \
  '  Must be in Discord server: false' \
  '  Subscriber role:' \
  '    Require subscriber role to join: false' \
  '    Subscriber roles: []' \
  '    Require all of the listed roles: false' > "$linking"
printf 'fixture\n' > "$gate_jar"

config_before_check="$(cat "$discord_config")"
linking_before_check="$(cat "$linking")"
DISCORDSRV_ENV_FILE="$settings" \
DISCORDSRV_CONFIG_FILE="$discord_config" \
DISCORDSRV_LINKING_FILE="$linking" \
DISCORD_GUILD_GATE_CONFIG_FILE="$gate_config" \
DISCORD_GUILD_GATE_JAR="$gate_jar" \
  "$root_dir/scripts/configure-discordsrv-guilds.sh" --check >/dev/null
if [ "$(cat "$discord_config")" != "$config_before_check" ] ||
    [ "$(cat "$linking")" != "$linking_before_check" ] ||
    [ -e "$gate_config" ]; then
  echo "FAIL: --check changed Discord Guild configuration" >&2
  exit 1
fi

output="$(
  DISCORDSRV_ENV_FILE="$settings" \
  DISCORDSRV_CONFIG_FILE="$discord_config" \
  DISCORDSRV_LINKING_FILE="$linking" \
  DISCORD_GUILD_GATE_CONFIG_FILE="$gate_config" \
  DISCORD_GUILD_GATE_JAR="$gate_jar" \
    "$root_dir/scripts/configure-discordsrv-guilds.sh"
)"

if [ "$output" != "OK: Discord の Guild, Channel, 連携ロール, 参加制限を設定しました" ]; then
  echo "FAIL: unexpected success message: $output" >&2
  exit 1
fi

grep -Fqx 'Channels: {"global": "34567890123456789"}' "$discord_config"
grep -Fqx 'MinecraftDiscordAccountLinkedRoleNameToAddUserTo: "67890123456789012"' "$discord_config"
grep -q '^  Must be in Discord server: true$' "$linking"
grep -Fqx '    Require subscriber role to join: true' "$linking"
grep -Fqx '    Subscriber roles: ["45678901234567890", "56789012345678901"]' "$linking"
grep -Fqx '    Require all of the listed roles: false' "$linking"
grep -q '^  - "12345678901234567"$' "$gate_config"
grep -q '^  - "23456789012345678"$' "$gate_config"
grep -q '^membership-cache-seconds: 30$' "$gate_config"
grep -Fqx 'not-allowed-message: "&c参加するには、許可された Discord サーバーへの参加が必要です"' "$gate_config"
if [ "$(sed -n '1p' "$gate_config")" != '# scripts/configure-discordsrv-guilds.sh により自動生成' ] ||
    [ "$(sed -n '2p' "$gate_config")" != '# 直接編集しないでください' ]; then
  echo "FAIL: generated config header is incorrect" >&2
  exit 1
fi

printf '%s\n' \
  'DISCORD_REQUIRED_GUILD_IDS=12345678901234567' \
  'DISCORD_CHAT_CHANNEL_ID=34567890123456789' \
  'DISCORD_LINKED_ROLE_ID=' \
  'DISCORD_REQUIRED_ROLE_IDS=' \
  'DISCORD_REQUIRE_ALL_ROLES=false' > "$settings"
DISCORDSRV_ENV_FILE="$settings" \
DISCORDSRV_CONFIG_FILE="$discord_config" \
DISCORDSRV_LINKING_FILE="$linking" \
DISCORD_GUILD_GATE_CONFIG_FILE="$gate_config" \
DISCORD_GUILD_GATE_JAR="$gate_jar" \
  "$root_dir/scripts/configure-discordsrv-guilds.sh" >/dev/null
grep -Fqx '    Require subscriber role to join: false' "$linking"
grep -Fqx '    Subscriber roles: []' "$linking"
grep -Fqx 'MinecraftDiscordAccountLinkedRoleNameToAddUserTo: ""' "$discord_config"

printf '%s\n' \
  'DISCORD_REQUIRED_GUILD_IDS=invalid' \
  'DISCORD_CHAT_CHANNEL_ID=34567890123456789' \
  'DISCORD_LINKED_ROLE_ID=67890123456789012' \
  'DISCORD_REQUIRED_ROLE_IDS=' \
  'DISCORD_REQUIRE_ALL_ROLES=false' > "$settings"
if DISCORDSRV_ENV_FILE="$settings" \
    DISCORDSRV_CONFIG_FILE="$discord_config" \
    DISCORDSRV_LINKING_FILE="$linking" \
    DISCORD_GUILD_GATE_CONFIG_FILE="$gate_config" \
    DISCORD_GUILD_GATE_JAR="$gate_jar" \
    "$root_dir/scripts/configure-discordsrv-guilds.sh" >/dev/null 2>&1; then
  echo "FAIL: invalid Guild ID was accepted" >&2
  exit 1
fi

printf '%s\n' \
  'DISCORD_REQUIRED_GUILD_IDS=10000000000000001,10000000000000002,10000000000000003,10000000000000004,10000000000000005,10000000000000006,10000000000000007,10000000000000008,10000000000000009,10000000000000010,10000000000000011' \
  'DISCORD_CHAT_CHANNEL_ID=34567890123456789' \
  'DISCORD_LINKED_ROLE_ID=67890123456789012' \
  'DISCORD_REQUIRED_ROLE_IDS=' \
  'DISCORD_REQUIRE_ALL_ROLES=false' > "$settings"
if DISCORDSRV_ENV_FILE="$settings" \
    DISCORDSRV_CONFIG_FILE="$discord_config" \
    DISCORDSRV_LINKING_FILE="$linking" \
    DISCORD_GUILD_GATE_CONFIG_FILE="$gate_config" \
    DISCORD_GUILD_GATE_JAR="$gate_jar" \
    "$root_dir/scripts/configure-discordsrv-guilds.sh" >/dev/null 2>&1; then
  echo "FAIL: too many Guild IDs were accepted" >&2
  exit 1
fi

printf '%s\n' \
  'DISCORD_REQUIRED_GUILD_IDS=1234567890 1234567' \
  'DISCORD_CHAT_CHANNEL_ID=34567890123456789' \
  'DISCORD_LINKED_ROLE_ID=67890123456789012' \
  'DISCORD_REQUIRED_ROLE_IDS=' \
  'DISCORD_REQUIRE_ALL_ROLES=false' > "$settings"
if DISCORDSRV_ENV_FILE="$settings" \
    DISCORDSRV_CONFIG_FILE="$discord_config" \
    DISCORDSRV_LINKING_FILE="$linking" \
    DISCORD_GUILD_GATE_CONFIG_FILE="$gate_config" \
    DISCORD_GUILD_GATE_JAR="$gate_jar" \
    "$root_dir/scripts/configure-discordsrv-guilds.sh" >/dev/null 2>&1; then
  echo "FAIL: Guild ID containing internal whitespace was accepted" >&2
  exit 1
fi

printf '%s\n' \
  'DISCORD_REQUIRED_GUILD_IDS=12345678901234567' \
  'DISCORD_CHAT_CHANNEL_ID=invalid' \
  'DISCORD_LINKED_ROLE_ID=67890123456789012' \
  'DISCORD_REQUIRED_ROLE_IDS=' \
  'DISCORD_REQUIRE_ALL_ROLES=false' > "$settings"
if DISCORDSRV_ENV_FILE="$settings" \
    DISCORDSRV_CONFIG_FILE="$discord_config" \
    DISCORDSRV_LINKING_FILE="$linking" \
    DISCORD_GUILD_GATE_CONFIG_FILE="$gate_config" \
    DISCORD_GUILD_GATE_JAR="$gate_jar" \
    "$root_dir/scripts/configure-discordsrv-guilds.sh" >/dev/null 2>&1; then
  echo "FAIL: invalid Channel ID was accepted" >&2
  exit 1
fi

printf '%s\n' \
  'DISCORD_REQUIRED_GUILD_IDS=12345678901234567' \
  'DISCORD_CHAT_CHANNEL_ID=34567890123456789' \
  'DISCORD_LINKED_ROLE_ID=invalid' \
  'DISCORD_REQUIRED_ROLE_IDS=' \
  'DISCORD_REQUIRE_ALL_ROLES=false' > "$settings"
if DISCORDSRV_ENV_FILE="$settings" \
    DISCORDSRV_CONFIG_FILE="$discord_config" \
    DISCORDSRV_LINKING_FILE="$linking" \
    DISCORD_GUILD_GATE_CONFIG_FILE="$gate_config" \
    DISCORD_GUILD_GATE_JAR="$gate_jar" \
    "$root_dir/scripts/configure-discordsrv-guilds.sh" >/dev/null 2>&1; then
  echo "FAIL: invalid linked-account Role ID was accepted" >&2
  exit 1
fi

printf '%s\n' \
  'DISCORD_REQUIRED_GUILD_IDS=12345678901234567' \
  'DISCORD_CHAT_CHANNEL_ID=34567890123456789' \
  'DISCORD_LINKED_ROLE_ID=67890123456789012' \
  'DISCORD_REQUIRED_ROLE_IDS=invalid' \
  'DISCORD_REQUIRE_ALL_ROLES=false' > "$settings"
if DISCORDSRV_ENV_FILE="$settings" \
    DISCORDSRV_CONFIG_FILE="$discord_config" \
    DISCORDSRV_LINKING_FILE="$linking" \
    DISCORD_GUILD_GATE_CONFIG_FILE="$gate_config" \
    DISCORD_GUILD_GATE_JAR="$gate_jar" \
    "$root_dir/scripts/configure-discordsrv-guilds.sh" >/dev/null 2>&1; then
  echo "FAIL: invalid Role ID was accepted" >&2
  exit 1
fi

printf '%s\n' \
  'DISCORD_REQUIRED_GUILD_IDS=12345678901234567' \
  'DISCORD_CHAT_CHANNEL_ID=34567890123456789' \
  'DISCORD_LINKED_ROLE_ID=67890123456789012' \
  'DISCORD_REQUIRED_ROLE_IDS=' \
  'DISCORD_REQUIRE_ALL_ROLES=invalid' > "$settings"
if DISCORDSRV_ENV_FILE="$settings" \
    DISCORDSRV_CONFIG_FILE="$discord_config" \
    DISCORDSRV_LINKING_FILE="$linking" \
    DISCORD_GUILD_GATE_CONFIG_FILE="$gate_config" \
    DISCORD_GUILD_GATE_JAR="$gate_jar" \
    "$root_dir/scripts/configure-discordsrv-guilds.sh" >/dev/null 2>&1; then
  echo "FAIL: invalid Role mode was accepted" >&2
  exit 1
fi

echo "OK: Discord Guild configuration fixtures passed"
