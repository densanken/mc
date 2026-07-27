#!/usr/bin/env sh
set -eu

root_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
env_file="${MC_ENV_FILE:-$root_dir/.env}"

read_required_identity() {
  identity_name="$1"
  awk -F= -v name="$identity_name" '
    $1 == name {
      count++
      value = substr($0, index($0, "=") + 1)
    }
    END {
      if (count != 1 || value !~ /^[0-9]+$/) exit 1
      print value
    }
  ' "$env_file"
}

configured_uid="$(read_required_identity MINECRAFT_UID)" || {
  echo "ERROR: MINECRAFT_UID は1つの数値で設定してください" >&2
  exit 1
}
configured_gid="$(read_required_identity MINECRAFT_GID)" || {
  echo "ERROR: MINECRAFT_GID は1つの数値で設定してください" >&2
  exit 1
}
if [ "$configured_uid" != "$(id -u)" ] || [ "$configured_gid" != "$(id -g)" ]; then
  echo "ERROR: MINECRAFT_UID/GID は実行ユーザーと一致させてください" >&2
  exit 1
fi

echo "OK: Minecraft の実行 UID/GID を確認しました"
