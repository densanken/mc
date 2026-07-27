#!/usr/bin/env sh
set -eu
umask 077

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

discord_config="${DISCORDSRV_CONFIG_FILE:-$root_dir/minecraft/plugins/DiscordSRV/config.yml}"
discord_messages="${DISCORDSRV_MESSAGES_FILE:-$root_dir/minecraft/plugins/DiscordSRV/messages.yml}"

require_file() {
  if [ ! -f "$1" ]; then
    echo "ERROR: 必要なファイルがありません: $1" >&2
    echo "       先に Minecraft を一度起動して設定ファイルを生成してください" >&2
    exit 1
  fi
}

require_file "$discord_config"
require_file "$discord_messages"

config_temporary="${discord_config}.tmp.$$"
messages_temporary="${discord_messages}.tmp.$$"
trap 'rm -f "$config_temporary" "$messages_temporary"' EXIT HUP INT TERM

cp "$discord_config" "$config_temporary"
cp "$discord_messages" "$messages_temporary"

perl -0pi -e '
  sub replace_setting {
    my ($key, $value) = @_;
    my $count = s/^\Q$key\E:.*$/$key: $value/mg;
    die "unexpected setting count for $key: $count\n" unless $count == 1;
  }

  replace_setting("Experiment_WebhookChatMessageDelivery", "true");
  replace_setting("Experiment_WebhookChatMessageUsernameFormat", "\"%displayname%\"");
  replace_setting("Experiment_WebhookChatMessageFormat", "\"%message%\"");
  replace_setting("Experiment_WebhookChatMessageUsernameFromDiscord", "false");
  replace_setting("Experiment_WebhookChatMessageAvatarFromDiscord", "false");
' "$config_temporary"

perl -0pi -e '
  my $discord_to_minecraft_count = s/^DiscordToMinecraftChatMessageFormat:.*$/DiscordToMinecraftChatMessageFormat: "[<aqua>Discord<\/aqua>] %name%%reply% » %message%"/mg;
  die "unexpected setting count for DiscordToMinecraftChatMessageFormat: $discord_to_minecraft_count\n" unless $discord_to_minecraft_count == 1;

  my $discord_to_minecraft_no_role_count = s/^DiscordToMinecraftChatMessageFormatNoRole:.*$/DiscordToMinecraftChatMessageFormatNoRole: "[<aqua>Discord<\/aqua>] %name%%reply% » %message%"/mg;
  die "unexpected setting count for DiscordToMinecraftChatMessageFormatNoRole: $discord_to_minecraft_no_role_count\n" unless $discord_to_minecraft_no_role_count == 1;

  sub replace_in_block {
    my ($block_ref, $pattern, $replacement, $label) = @_;
    my $count = $$block_ref =~ s/$pattern/$replacement/mg;
    die "unexpected setting count for $label: $count\n" unless $count == 1;
  }

  my @notifications = (
    ["MinecraftPlayerJoinMessage", "サーバーに参加しました", "false"],
    ["MinecraftPlayerFirstJoinMessage", "初めてサーバーに参加しました", "false"],
    ["MinecraftPlayerLeaveMessage", "サーバーから退出しました", "false"],
    ["MinecraftPlayerDeathMessage", "%deathmessage%", "true"],
    ["MinecraftPlayerAchievementMessage", "進捗「%achievement%」を達成しました", "true"]
  );

  for my $notification (@notifications) {
    my ($section, $content, $enabled) = @$notification;
    my $section_count = 0;

    s{^(\Q$section\E:\R)(.*?)(?=^\S|\z)}{
      my $heading = $1;
      my $block = $2;

      replace_in_block(\$block, qr/^  Enabled:.*$/m, "  Enabled: $enabled", "$section.Enabled");
      replace_in_block(\$block, qr/^    Enable:.*$/m, "    Enable: true", "$section.Webhook.Enable");
      replace_in_block(\$block, qr/^    AvatarUrl:.*$/m, "    AvatarUrl: \"\"", "$section.Webhook.AvatarUrl");
      replace_in_block(\$block, qr/^    Name:.*$/m, "    Name: \"%username%\"", "$section.Webhook.Name");
      replace_in_block(\$block, qr/^  Content:.*$/m, "  Content: \"$content\"", "$section.Content");
      replace_in_block(\$block, qr/^    Enabled:.*$/m, "    Enabled: false", "$section.Embed.Enabled");

      $section_count++;
      $heading . $block;
    }gems;

    die "unexpected section count for $section: $section_count\n" unless $section_count == 1;
  }

  my $linked_count = s/^DiscordAccountLinked:.*$/DiscordAccountLinked: "Minecraftアカウント（%name%）との連携が完了しました。Minecraftサーバーへ接続し直してください。"/mg;
  die "unexpected setting count for DiscordAccountLinked: $linked_count\n" unless $linked_count == 1;

  my $already_linked_count = s/^DiscordAccountAlreadyLinked:.*$/DiscordAccountAlreadyLinked: "すでにMinecraftアカウント（%username%）と連携されています。Minecraftサーバーへ接続し直してください。"/mg;
  die "unexpected setting count for DiscordAccountAlreadyLinked: $already_linked_count\n" unless $already_linked_count == 1;
' "$messages_temporary"

if [ "$mode" = "check" ]; then
  echo "OK: DiscordSRV の日本語メッセージと Webhook 通知の設定形式を確認しました"
  exit 0
fi

chmod 0600 "$config_temporary"
chmod 0644 "$messages_temporary"
mv "$config_temporary" "$discord_config"
mv "$messages_temporary" "$discord_messages"
trap - EXIT HUP INT TERM

echo "OK: DiscordSRV の日本語メッセージと Webhook 通知を設定しました"
