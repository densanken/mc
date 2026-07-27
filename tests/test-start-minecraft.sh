#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

token_file="$fixture/discordsrv-token"
data_dir="$fixture/data"
start_script="$fixture/start"
token_link="$data_dir/plugins/DiscordSRV/.token"
icon_source="$fixture/server-icon.png"
icon_target="$data_dir/server-icon.png"

printf 'test-token\n' > "$token_file"
printf 'png fixture\n' > "$icon_source"
printf '#!/usr/bin/env sh\nexit 0\n' > "$start_script"
chmod 0700 "$start_script"

DISCORDSRV_TOKEN_FILE="$token_file" \
SERVER_ICON_SOURCE="$icon_source" \
MINECRAFT_DATA_DIR="$data_dir" \
MINECRAFT_START_SCRIPT="$start_script" \
  "$root_dir/scripts/start-minecraft.sh"

if [ ! -L "$token_link" ] || [ "$(readlink "$token_link")" != "$token_file" ]; then
  echo "FAIL: DiscordSRV token secret was not linked" >&2
  exit 1
fi
if ! cmp "$icon_source" "$icon_target"; then
  echo "FAIL: managed server icon was not copied" >&2
  exit 1
fi
if [ "$(stat -f '%Lp' "$icon_target" 2>/dev/null || stat -c '%a' "$icon_target")" != 644 ]; then
  echo "FAIL: managed server icon mode is not 0644" >&2
  exit 1
fi

: > "$token_file"
DISCORDSRV_TOKEN_FILE="$token_file" \
SERVER_ICON_SOURCE="$icon_source" \
MINECRAFT_DATA_DIR="$data_dir" \
MINECRAFT_START_SCRIPT="$start_script" \
  "$root_dir/scripts/start-minecraft.sh"

if [ -e "$token_link" ] || [ -L "$token_link" ]; then
  echo "FAIL: empty DiscordSRV token secret left a token link" >&2
  exit 1
fi

SERVER_ICON_SOURCE="$fixture/missing-icon.png" \
MINECRAFT_DATA_DIR="$data_dir" \
MINECRAFT_START_SCRIPT="$start_script" \
  "$root_dir/scripts/start-minecraft.sh"
if [ -e "$icon_target" ]; then
  echo "FAIL: removing the managed server icon source left the runtime icon" >&2
  exit 1
fi

fake_bin="$fixture/bin"
root_data_dir="$fixture/root-data"
chown_log="$fixture/chown.log"
mkdir -p "$fake_bin"
printf '#!/usr/bin/env sh\nprintf "0\\n"\n' > "$fake_bin/id"
# "$*" と "$CHOWN_LOG" は生成先の script 内で展開する
# shellcheck disable=SC2016
printf '#!/usr/bin/env sh\nprintf "%%s\\n" "$*" > "$CHOWN_LOG"\n' > "$fake_bin/chown"
chmod 0700 "$fake_bin/id" "$fake_bin/chown"

CHOWN_LOG="$chown_log" \
PATH="$fake_bin:$PATH" \
DISCORDSRV_TOKEN_FILE="$token_file" \
SERVER_ICON_SOURCE="$fixture/missing-icon.png" \
MINECRAFT_DATA_DIR="$root_data_dir" \
MINECRAFT_START_SCRIPT="$start_script" \
  env UID=1234 GID=2345 "$root_dir/scripts/start-minecraft.sh"

if [ "$(cat "$chown_log")" != "1234:2345 $root_data_dir/plugins $root_data_dir/plugins/DiscordSRV" ]; then
  echo "FAIL: DiscordSRV data directory ownership was not aligned with the Minecraft process" >&2
  exit 1
fi

echo "OK: DiscordSRV startup preparation passed"
