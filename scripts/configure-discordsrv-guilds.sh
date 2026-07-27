#!/usr/bin/env sh
set -eu

# .discordsrv.env の Discord Guild, Channel, Role ID を runtime config に反映する
# DiscordGuildGate は指定した Discord Guild のいずれか一つへの所属を要求する

root_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
mode="apply"
case "${1:-}" in
  '') ;;
  --check) mode="check" ;;
  *)
    echo "usage: $0 [--check]" >&2
    exit 2
    ;;
esac
if [ "$#" -gt 1 ]; then
  echo "usage: $0 [--check]" >&2
  exit 2
fi

settings_file="${DISCORDSRV_ENV_FILE:-$root_dir/.discordsrv.env}"
discord_config_file="${DISCORDSRV_CONFIG_FILE:-$root_dir/minecraft/plugins/DiscordSRV/config.yml}"
linking_file="${DISCORDSRV_LINKING_FILE:-$root_dir/minecraft/plugins/DiscordSRV/linking.yml}"
gate_config_file="${DISCORD_GUILD_GATE_CONFIG_FILE:-$root_dir/minecraft/plugins/DiscordGuildGate/config.yml}"
gate_jar="${DISCORD_GUILD_GATE_JAR:-$root_dir/minecraft/plugins/DiscordGuildGate.jar}"
max_guilds=10

if [ ! -r "$settings_file" ]; then
  echo "ERROR: 設定ファイルを読めません: $settings_file" >&2
  echo "       .discordsrv.env.example をコピーして Discord の ID を設定してください" >&2
  exit 1
fi

read_setting() {
  key="$1"
  awk -v key="$key" '
  $0 ~ ("^[[:space:]]*" key "[[:space:]]*=") {
    count++
    line = $0
    sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "", line)
    value = line
  }
  END {
    if (count != 1) exit 1
    print value
  }
' "$settings_file"
}

setting_equals() {
  file="$1"
  key="$2"
  expected="$3"
  awk -v key="$key" -v expected="$expected" '
    $0 ~ ("^[[:space:]]*" key "[[:space:]]*:") {
      count++
      value = substr($0, index($0, ":") + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      if (value == expected) matches++
    }
    END { exit !(count == 1 && matches == 1) }
  ' "$file"
}

guild_ids="$(read_setting DISCORD_REQUIRED_GUILD_IDS)" || {
    echo "ERROR: $settings_file には DISCORD_REQUIRED_GUILD_IDS を 1 回だけ設定してください" >&2
    exit 1
  }
channel_id="$(read_setting DISCORD_CHAT_CHANNEL_ID)" || {
    echo "ERROR: $settings_file には DISCORD_CHAT_CHANNEL_ID を 1 回だけ設定してください" >&2
    exit 1
  }
linked_role_id="$(read_setting DISCORD_LINKED_ROLE_ID)" || {
    echo "ERROR: $settings_file には DISCORD_LINKED_ROLE_ID を 1 回だけ設定してください" >&2
    exit 1
  }
role_ids="$(read_setting DISCORD_REQUIRED_ROLE_IDS)" || {
    echo "ERROR: $settings_file には DISCORD_REQUIRED_ROLE_IDS を 1 回だけ設定してください" >&2
    exit 1
  }
require_all_roles="$(read_setting DISCORD_REQUIRE_ALL_ROLES)" || {
    echo "ERROR: $settings_file には DISCORD_REQUIRE_ALL_ROLES を 1 回だけ設定してください" >&2
    exit 1
  }

# .env 形式の Discord Guild ID はカンマ区切りで受け付ける
# 値の前後の空白だけを除き、内部空白と YAML・shell の特殊文字を拒否する
guild_ids="$(printf '%s' "$guild_ids" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
if ! printf '%s\n' "$guild_ids" | grep -Eq '^[0-9]{17,20}(,[0-9]{17,20})*$'; then
  echo "ERROR: DISCORD_REQUIRED_GUILD_IDS は 17〜20 桁の Discord Guild ID をカンマ区切りで指定してください" >&2
  exit 1
fi
guild_count="$(printf '%s\n' "$guild_ids" | awk -F, '{ print NF }')"
if [ "$guild_count" -gt "$max_guilds" ]; then
  echo "ERROR: DISCORD_REQUIRED_GUILD_IDS は最大 $max_guilds 件まで指定できます" >&2
  exit 1
fi
channel_id="$(printf '%s' "$channel_id" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
if ! printf '%s\n' "$channel_id" | grep -Eq '^[0-9]{17,20}$'; then
  echo "ERROR: DISCORD_CHAT_CHANNEL_ID は 17〜20 桁の Discord Channel ID で指定してください" >&2
  exit 1
fi
linked_role_id="$(printf '%s' "$linked_role_id" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
if [ -n "$linked_role_id" ] && \
    ! printf '%s\n' "$linked_role_id" | grep -Eq '^[0-9]{17,20}$'; then
  echo "ERROR: DISCORD_LINKED_ROLE_ID は 17〜20 桁の Discord Role ID で指定してください" >&2
  exit 1
fi
role_ids="$(printf '%s' "$role_ids" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
if [ -n "$role_ids" ] && \
    ! printf '%s\n' "$role_ids" | grep -Eq '^[0-9]{17,20}(,[0-9]{17,20})*$'; then
  echo "ERROR: DISCORD_REQUIRED_ROLE_IDS は 17〜20 桁の Discord Role ID をカンマ区切りで指定してください" >&2
  exit 1
fi
require_all_roles="$(printf '%s' "$require_all_roles" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
case "$require_all_roles" in
  true | false) ;;
  *)
    echo "ERROR: DISCORD_REQUIRE_ALL_ROLES は true または false で指定してください" >&2
    exit 1
    ;;
esac

if [ -n "$role_ids" ]; then
  require_subscriber_role="true"
  subscriber_roles="$(printf '%s\n' "$role_ids" | awk -F, '
    BEGIN { printf "[" }
    {
      for (i = 1; i <= NF; i++) {
        if (i > 1) printf ", "
        printf "\"%s\"", $i
      }
    }
    END { print "]" }
  ')"
else
  require_subscriber_role="false"
  subscriber_roles="[]"
fi

if [ ! -f "$discord_config_file" ]; then
  echo "ERROR: DiscordSRV の config.yml がありません: $discord_config_file" >&2
  echo "       先に Minecraft を一度起動して DiscordSRV の設定を生成してください" >&2
  exit 1
fi
if [ ! -f "$linking_file" ]; then
  echo "ERROR: DiscordSRV の linking.yml がありません: $linking_file" >&2
  echo "       先に Minecraft を一度起動して DiscordSRV の設定を生成してください" >&2
  exit 1
fi

if [ ! -f "$gate_jar" ]; then
  echo "ERROR: DiscordGuildGate jar がありません: $gate_jar" >&2
  echo "       先に ./scripts/build-discord-guild-gate.sh を実行してください" >&2
  exit 1
fi

if [ "$(grep -c '^[[:space:]]*Must be in Discord server:' "$linking_file")" -ne 1 ]; then
  echo "ERROR: linking.yml に Must be in Discord server がありません。DiscordSRV の設定形式を確認してください" >&2
  exit 1
fi
for setting in \
  'Require subscriber role to join:' \
  'Subscriber roles:' \
  'Require all of the listed roles:'
do
  if [ "$(grep -c "^[[:space:]]*$setting" "$linking_file")" -ne 1 ]; then
    echo "ERROR: linking.yml に $setting がありません。DiscordSRV の設定形式を確認してください" >&2
    exit 1
  fi
done
if [ "$(grep -c '^Channels:' "$discord_config_file")" -ne 1 ] ||
    ! grep -Eq '^Channels:[[:space:]]*\{[^{}]*\}[[:space:]]*$' "$discord_config_file"; then
  echo "ERROR: config.yml に Channels がありません。DiscordSRV の設定形式を確認してください" >&2
  exit 1
fi
if [ "$(grep -c '^MinecraftDiscordAccountLinkedRoleNameToAddUserTo:' "$discord_config_file")" -ne 1 ]; then
  echo "ERROR: config.yml に MinecraftDiscordAccountLinkedRoleNameToAddUserTo がありません。DiscordSRV の設定形式を確認してください" >&2
  exit 1
fi

if [ "$mode" = "check" ]; then
  echo "OK: Discord の Guild, Channel, 連携ロール, 参加制限の入力を確認しました"
  exit 0
fi

# DiscordSRV 標準の true は、Bot と共通する Discord Guild のいずれかへの所属を要求する
# DiscordGuildGate が許可対象の部分集合を確認し、独自 plugin が停止した場合も標準判定を残す
perl -0pi -e 's/^(\h*Must be in Discord server:)[^\n]*$/$1 . q{ true}/me' "$linking_file"
DISCORD_REQUIRE_SUBSCRIBER_ROLE="$require_subscriber_role" \
DISCORD_SUBSCRIBER_ROLES="$subscriber_roles" \
DISCORD_REQUIRE_ALL_ROLES="$require_all_roles" \
  perl -pi -e '
    s/^(\s*Require subscriber role to join:).*/$1 $ENV{DISCORD_REQUIRE_SUBSCRIBER_ROLE}/;
    s/^(\s*Subscriber roles:).*/$1 $ENV{DISCORD_SUBSCRIBER_ROLES}/;
    s/^(\s*Require all of the listed roles:).*/$1 $ENV{DISCORD_REQUIRE_ALL_ROLES}/;
  ' "$linking_file"
DISCORD_CHAT_CHANNEL_ID="$channel_id" perl -pi -e \
  's/^Channels:.*/q(Channels: {"global": ") . $ENV{DISCORD_CHAT_CHANNEL_ID} . q("})/e' \
  "$discord_config_file"
DISCORD_LINKED_ROLE_ID="$linked_role_id" perl -pi -e \
  's/^MinecraftDiscordAccountLinkedRoleNameToAddUserTo:.*/q(MinecraftDiscordAccountLinkedRoleNameToAddUserTo: ") . $ENV{DISCORD_LINKED_ROLE_ID} . q(")/e' \
  "$discord_config_file"

if ! grep -Fqx "Channels: {\"global\": \"$channel_id\"}" "$discord_config_file"; then
  echo "ERROR: DiscordSRV の Channel ID を config.yml に反映できませんでした" >&2
  exit 1
fi
if ! grep -Fqx "MinecraftDiscordAccountLinkedRoleNameToAddUserTo: \"$linked_role_id\"" "$discord_config_file"; then
  echo "ERROR: 連携済みアカウントへ付与する Discord Role ID を config.yml に反映できませんでした" >&2
  exit 1
fi
if ! setting_equals "$linking_file" \
      "Require subscriber role to join" "$require_subscriber_role" || \
    ! setting_equals "$linking_file" "Subscriber roles" "$subscriber_roles" || \
    ! setting_equals "$linking_file" \
      "Require all of the listed roles" "$require_all_roles"; then
  echo "ERROR: Discord の Role 条件を linking.yml に反映できませんでした" >&2
  exit 1
fi

mkdir -p "$(dirname "$gate_config_file")"
temporary_config="${gate_config_file}.tmp.$$"
trap 'rm -f "$temporary_config"' EXIT HUP INT TERM
{
  echo "# scripts/configure-discordsrv-guilds.sh により自動生成"
  echo "# 直接編集しないでください"
  echo "allowed-guild-ids:"
  printf '%s\n' "$guild_ids" | tr ',' '\n' | sed 's/^/  - "/;s/$/"/'
  echo 'not-allowed-message: "&c参加するには、許可された Discord サーバーへの参加が必要です"'
  echo 'verification-failed-message: "&cDiscord サーバーへの参加状況を確認できませんでした。しばらくしてから再試行してください"'
  echo 'membership-cache-seconds: 30'
  echo 'discord-request-timeout-seconds: 5'
} > "$temporary_config"
mv "$temporary_config" "$gate_config_file"
trap - EXIT HUP INT TERM

echo "OK: Discord の Guild, Channel, 連携ロール, 参加制限を設定しました"
