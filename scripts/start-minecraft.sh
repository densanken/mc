#!/usr/bin/env sh
set -eu

# DiscordSRV は data directory の .token を config.yml より優先して読み込む
discordsrv_token_source="${DISCORDSRV_TOKEN_FILE:-/run/secrets/discordsrv_token}"
minecraft_data_dir="${MINECRAFT_DATA_DIR:-/data}"
minecraft_start_script="${MINECRAFT_START_SCRIPT:-/image/scripts/start}"
server_icon_source="${SERVER_ICON_SOURCE:-/extras/server-icon.png}"
server_icon_target="$minecraft_data_dir/server-icon.png"
minecraft_plugins_dir="$minecraft_data_dir/plugins"
discordsrv_data_dir="$minecraft_plugins_dir/DiscordSRV"
discordsrv_token_target="$discordsrv_data_dir/.token"

mkdir -p "$discordsrv_data_dir"
# /data 自体の所有者が一致すると base image は配下を chown しないため、ここで作る directory の所有者を合わせる
if [ "$(id -u)" -eq 0 ]; then
  # UID と GID は compose.yml の environment から渡される
  # shellcheck disable=SC3028
  chown "${UID:-1000}:${GID:-1000}" "$minecraft_plugins_dir" "$discordsrv_data_dir"
fi
if [ -s "$discordsrv_token_source" ]; then
  ln -sfn "$discordsrv_token_source" "$discordsrv_token_target"
else
  rm -f "$discordsrv_token_target"
fi

if [ -f "$server_icon_source" ]; then
  server_icon_temporary="${server_icon_target}.tmp.$$"
  trap 'rm -f "$server_icon_temporary"' EXIT HUP INT TERM
  cp "$server_icon_source" "$server_icon_temporary"
  chmod 0644 "$server_icon_temporary"
  mv "$server_icon_temporary" "$server_icon_target"
  trap - EXIT HUP INT TERM
else
  rm -f "$server_icon_target"
fi

# server.properties と RCON client config に認証情報が書かれるため、生成時から owner だけに読ませる
umask 077
exec "$minecraft_start_script" "$@"
