#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

mkdir -p "$fixture/bin" "$fixture/scripts"
cp "$root_dir/compose.yml" "$fixture/compose.yml"
cp "$root_dir/.env.example" "$fixture/.env.example"
cp "$root_dir/scripts/update-image-digests.sh" "$fixture/scripts/update-image-digests.sh"

minecraft_digest="$(
  perl -ne 'if (m|itzg/minecraft-server:java25@(sha256:[0-9a-f]{64})|) { print $1; exit }' \
    "$fixture/compose.yml"
)"
backup_digest="$(
  perl -ne 'if (m|itzg/mc-backup@(sha256:[0-9a-f]{64})|) { print $1; exit }' \
    "$fixture/compose.yml"
)"
playit_digest="$(
  perl -ne 'if (m|ghcr.io/playit-cloud/playit-agent@(sha256:[0-9a-f]{64})|) { print $1; exit }' \
    "$fixture/compose.yml"
)"
stale_digest="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

# 同じ image を使う2サービスのうち、後ろの1件だけを古い digest にする
perl -pi -e "
  if (/itzg\\/minecraft-server:java25\\@sha256:/) {
    \$seen++;
    if (\$seen == 2) {
      s/sha256:[0-9a-f]{64}/$stale_digest/;
    }
  }
" "$fixture/compose.yml"

cat > "$fixture/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-} ${2:-}" in
  "pull --quiet")
    exit 0
    ;;
  "image inspect")
    case "$3" in
      itzg/minecraft-server:java25)
        printf 'itzg/minecraft-server@%s\n' "$MOCK_MINECRAFT_DIGEST"
        ;;
      itzg/mc-backup:latest)
        printf 'itzg/mc-backup@%s\n' "$MOCK_BACKUP_DIGEST"
        ;;
      ghcr.io/playit-cloud/playit-agent:latest)
        printf 'ghcr.io/playit-cloud/playit-agent@%s\n' "$MOCK_PLAYIT_DIGEST"
        ;;
      *)
        exit 1
        ;;
    esac
    ;;
  "compose --env-file")
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
DOCKER
chmod 0755 "$fixture/bin/docker"

PATH="$fixture/bin:$PATH" \
  MOCK_MINECRAFT_DIGEST="$minecraft_digest" \
  MOCK_BACKUP_DIGEST="$backup_digest" \
  MOCK_PLAYIT_DIGEST="$playit_digest" \
  "$fixture/scripts/update-image-digests.sh" >/dev/null

if [ "$(grep -Fc "image: itzg/minecraft-server:java25@$minecraft_digest" "$fixture/compose.yml")" -ne 2 ] ||
   grep -Fq "$stale_digest" "$fixture/compose.yml"; then
  echo "FAIL: stale duplicate Minecraft image digest was not updated" >&2
  exit 1
fi

echo "OK: image digest update fixtures passed"
