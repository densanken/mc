#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

mkdir -p "$fixture/config" "$fixture/minecraft/plugins"
printf 'paper fixture\n' > "$fixture/minecraft/paper-test.jar"
printf 'discordsrv fixture\n' > "$fixture/minecraft/plugins/DiscordSRV.jar"
printf 'gate fixture\n' > "$fixture/minecraft/plugins/DiscordGuildGate.jar"

hash_file() {
  local algorithm="$1"
  local file="$2"
  if command -v "sha${algorithm}sum" >/dev/null 2>&1; then
    "sha${algorithm}sum" "$file" | awk '{print $1}'
  else
    shasum -a "$algorithm" "$file" | awk '{print $1}'
  fi
}

paper_hash="$(hash_file 256 "$fixture/minecraft/paper-test.jar")"
discord_hash="$(hash_file 512 "$fixture/minecraft/plugins/DiscordSRV.jar")"
gate_hash="$(hash_file 256 "$fixture/minecraft/plugins/DiscordGuildGate.jar")"
printf '# slug\tversion_number\tsha512\tfilename\n' > "$fixture/config/modrinth-lock.tsv"
printf 'discordsrv\ttest\t%s\tDiscordSRV.jar\n' "$discord_hash" >> "$fixture/config/modrinth-lock.tsv"
printf '# sha256\tfilename\n' > "$fixture/config/discord-guild-gate-lock.tsv"
printf '%s\tDiscordGuildGate.jar\n' "$gate_hash" >> "$fixture/config/discord-guild-gate-lock.tsv"

verify() {
  MC_ROOT_DIR="$fixture" \
  PAPER_JAR_NAME="paper-test.jar" \
  PAPER_EXPECTED_SHA256="$paper_hash" \
  VERIFY_MODRINTH_API=false \
    "$root_dir/scripts/verify-jars.sh"
}

verify >/dev/null

cp "$fixture/minecraft/paper-test.jar" "$fixture/paper-test.jar"
printf 'tampered paper fixture\n' > "$fixture/minecraft/paper-test.jar"
if verify >/dev/null 2>&1; then
  echo "FAIL: Paper jar with a mismatched official hash was accepted" >&2
  exit 1
fi
mv "$fixture/paper-test.jar" "$fixture/minecraft/paper-test.jar"

mv "$fixture/minecraft/plugins/DiscordSRV.jar" "$fixture/DiscordSRV.jar"
if verify >/dev/null 2>&1; then
  echo "FAIL: missing Modrinth jar was accepted" >&2
  exit 1
fi
mv "$fixture/DiscordSRV.jar" "$fixture/minecraft/plugins/DiscordSRV.jar"

mv "$fixture/minecraft/plugins/DiscordGuildGate.jar" "$fixture/DiscordGuildGate.jar"
if verify >/dev/null 2>&1; then
  echo "FAIL: missing DiscordGuildGate jar was accepted" >&2
  exit 1
fi
mv "$fixture/DiscordGuildGate.jar" "$fixture/minecraft/plugins/DiscordGuildGate.jar"

printf 'unexpected\n' > "$fixture/minecraft/plugins/Unexpected.jar"
if verify >/dev/null 2>&1; then
  echo "FAIL: untracked jar was accepted" >&2
  exit 1
fi
rm "$fixture/minecraft/plugins/Unexpected.jar"

printf 'escape fixture\n' > "$fixture/minecraft/Escape.jar"
escape_hash="$(hash_file 512 "$fixture/minecraft/Escape.jar")"
mv "$fixture/minecraft/plugins/DiscordSRV.jar" "$fixture/DiscordSRV.jar"
printf 'escape\ttest\t%s\t../Escape.jar\n' "$escape_hash" > "$fixture/config/modrinth-lock.tsv"
if verify >/dev/null 2>&1; then
  echo "FAIL: path traversal in Modrinth lock was accepted" >&2
  exit 1
fi
rm "$fixture/minecraft/Escape.jar"
mv "$fixture/DiscordSRV.jar" "$fixture/minecraft/plugins/DiscordSRV.jar"
printf '# slug\tversion_number\tsha512\tfilename\n' > "$fixture/config/modrinth-lock.tsv"
printf 'discordsrv\ttest\t%s\tDiscordSRV.jar\n' "$discord_hash" >> "$fixture/config/modrinth-lock.tsv"

printf '%s\tDiscordGuildGate.jar\n' "$gate_hash" >> \
  "$fixture/config/discord-guild-gate-lock.tsv"
if verify >/dev/null 2>&1; then
  echo "FAIL: extra DiscordGuildGate lock entry was accepted" >&2
  exit 1
fi
printf '# sha256\tfilename\n' > "$fixture/config/discord-guild-gate-lock.tsv"
printf '%s\tDiscordGuildGate.jar\n' "$gate_hash" >> \
  "$fixture/config/discord-guild-gate-lock.tsv"

printf '# slug\tversion_number\tsha512\tfilename\n' > "$fixture/config/modrinth-lock.tsv"
printf 'discordsrv\ttest\t%s\tDiscordSRV.jar\n' "$discord_hash" >> \
  "$fixture/config/modrinth-lock.tsv"
cp "$fixture/minecraft/plugins/DiscordSRV.jar" \
  "$fixture/minecraft/plugins/DiscordSRV-old.jar"
printf 'discordsrv\told\t%s\tDiscordSRV-old.jar\n' "$discord_hash" >> \
  "$fixture/config/modrinth-lock.tsv"
if verify >/dev/null 2>&1; then
  echo "FAIL: duplicate Modrinth project slug was accepted" >&2
  exit 1
fi
rm "$fixture/minecraft/plugins/DiscordSRV-old.jar"

: > "$fixture/config/modrinth-lock.tsv"
for ((entry = 1; entry <= 256; entry++)); do
  printf 'invalid slug %s\ttest\tinvalid\tInvalid.jar\n' "$entry" >> \
    "$fixture/config/modrinth-lock.tsv"
done
if verify >/dev/null 2>&1; then
  echo "FAIL: 256 invalid Modrinth lock entries wrapped to success" >&2
  exit 1
fi

echo "OK: verify-jars fixtures passed"
