#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
jar="$root_dir/minecraft/plugins/DiscordGuildGate.jar"
lock_file="$root_dir/config/discord-guild-gate-lock.tsv"

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

"$root_dir/scripts/build-discord-guild-gate.sh"
first="$(sha256_file "$jar")"
"$root_dir/scripts/build-discord-guild-gate.sh"
second="$(sha256_file "$jar")"
if [ "$first" != "$second" ]; then
  echo "ERROR: DiscordGuildGate.jar を再現できません。lock file は変更しません" >&2
  exit 1
fi

next_lock="$(mktemp "$lock_file.next.XXXXXX")"
trap 'rm -f -- "$next_lock"' EXIT HUP INT TERM
printf '# sha256\tfilename\n%s\tDiscordGuildGate.jar\n' "$second" > "$next_lock"
chmod 0644 "$next_lock"
mv "$next_lock" "$lock_file"
next_lock=""
trap - EXIT HUP INT TERM

echo "OK: config/discord-guild-gate-lock.tsv を更新しました"
