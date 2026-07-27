#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

mkdir -p "$fixture/bin"
compose_file="$fixture/compose.yml"
output_file="$fixture/advancements-ja_jp.properties"
language_file="$fixture/ja_jp.json"
asset_index="$fixture/assets.json"
version_metadata="$fixture/version.json"
version_manifest="$fixture/version-manifest.json"

printf '      VERSION: "26.1.2"\n' > "$compose_file"
cat > "$language_file" <<'JSON'
{
  "advancements.story.mine_stone.description": "真新しいツルハシで石を採掘する",
  "advancements.story.mine_stone.title": "石器時代",
  "advancements.story.multiline.description": "1行目\n2行目",
  "advancements.story.root.description": "ゲームの核心と物語",
  "advancements.story.root.title": "Minecraft",
  "block.minecraft.stone": "石"
}
JSON
language_hash="$(shasum -a 1 "$language_file" | awk '{print $1}')"
language_size="$(wc -c < "$language_file" | tr -d ' ')"
jq -n \
  --arg hash "$language_hash" \
  --argjson size "$language_size" \
  '{objects: {"minecraft/lang/ja_jp.json": {hash: $hash, size: $size}}}' \
  > "$asset_index"
asset_index_hash="$(shasum -a 1 "$asset_index" | awk '{print $1}')"
jq -n \
  --arg sha1 "$asset_index_hash" \
  '{assetIndex: {url: "https://piston-meta.mojang.com/test/assets.json", sha1: $sha1}}' \
  > "$version_metadata"
version_hash="$(shasum -a 1 "$version_metadata" | awk '{print $1}')"
jq -n \
  --arg sha1 "$version_hash" \
  '{versions: [{id: "26.1.2", url: "https://piston-meta.mojang.com/test/version.json", sha1: $sha1}]}' \
  > "$version_manifest"

cat > "$fixture/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
output=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      output="$2"
      shift 2
      ;;
    -H)
      shift 2
      ;;
    -*) shift ;;
    *)
      url="$1"
      shift
      ;;
  esac
done
case "$url" in
  https://piston-meta.mojang.com/mc/game/version_manifest_v2.json)
    cp "$FAKE_VERSION_MANIFEST" "$output"
    ;;
  https://piston-meta.mojang.com/test/version.json)
    cp "$FAKE_VERSION_METADATA" "$output"
    ;;
  https://piston-meta.mojang.com/test/assets.json)
    cp "$FAKE_ASSET_INDEX" "$output"
    ;;
  https://resources.download.minecraft.net/*)
    cp "$FAKE_LANGUAGE_FILE" "$output"
    ;;
  *)
    echo "unexpected URL: $url" >&2
    exit 1
    ;;
esac
CURL
chmod 0755 "$fixture/bin/curl"

PATH="$fixture/bin:$PATH" \
FAKE_VERSION_MANIFEST="$version_manifest" \
FAKE_VERSION_METADATA="$version_metadata" \
FAKE_ASSET_INDEX="$asset_index" \
FAKE_LANGUAGE_FILE="$language_file" \
MINECRAFT_COMPOSE_FILE="$compose_file" \
ADVANCEMENT_TRANSLATIONS_FILE="$output_file" \
  "$root_dir/scripts/update-advancement-translations.sh" >/dev/null

grep -Fqx '# Minecraft version: 26.1.2' "$output_file"
grep -Fqx "# ja_jp.json SHA-1: $language_hash" "$output_file"
grep -Fqx 'advancements.story.mine_stone.description=真新しいツルハシで石を採掘する' "$output_file"
grep -Fqx 'advancements.story.mine_stone.title=石器時代' "$output_file"
grep -Fqx 'advancements.story.multiline.description=1行目\n2行目' "$output_file"
grep -Fqx 'advancements.story.root.description=ゲームの核心と物語' "$output_file"
grep -Fqx 'advancements.story.root.title=Minecraft' "$output_file"
if grep -q 'block.minecraft' "$output_file"; then
  echo "FAIL: 進捗以外の翻訳が辞書へ出力されました" >&2
  exit 1
fi

output_before_failure="$(cat "$output_file")"
printf 'tampered\n' >> "$language_file"
if PATH="$fixture/bin:$PATH" \
  FAKE_VERSION_MANIFEST="$version_manifest" \
  FAKE_VERSION_METADATA="$version_metadata" \
  FAKE_ASSET_INDEX="$asset_index" \
  FAKE_LANGUAGE_FILE="$language_file" \
  MINECRAFT_COMPOSE_FILE="$compose_file" \
  ADVANCEMENT_TRANSLATIONS_FILE="$output_file" \
    "$root_dir/scripts/update-advancement-translations.sh" >/dev/null 2>&1; then
  echo "FAIL: hash が一致しない言語ファイルを受け入れました" >&2
  exit 1
fi
if [ "$(cat "$output_file")" != "$output_before_failure" ]; then
  echo "FAIL: 更新失敗時に既存の辞書が変更されました" >&2
  exit 1
fi

printf 'OK: advancement translation update tests passed\n'
