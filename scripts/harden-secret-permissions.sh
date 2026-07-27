#!/usr/bin/env sh
set -eu

root_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

for path in \
  "$root_dir/.env" \
  "$root_dir/.discordsrv.env" \
  "$root_dir/minecraft/plugins/DiscordSRV/config.yml" \
  "$root_dir/minecraft/server.properties" \
  "$root_dir/minecraft/.rcon-cli.env" \
  "$root_dir/minecraft/.rcon-cli.yaml"
do
  if [ -e "$path" ]; then
    chmod 0600 "$path"
    echo "OK: mode 0600: $path"
  fi
done
