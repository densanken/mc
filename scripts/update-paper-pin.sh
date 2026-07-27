#!/usr/bin/env bash
set -euo pipefail

# PaperMC Fill API の最新 build へ Paper の pin を更新する
# 更新する値
#   compose.yml            VERSION / PAPER_BUILD
#   scripts/verify-jars.sh jar ファイル名 / paper_expected_sha256
#
# 実行方法
#   ./scripts/update-paper-pin.sh            # compose.yml の VERSION の最新 build へ更新
#   ./scripts/update-paper-pin.sh 26.1.3     # 指定 version の最新 build へ更新
#
# 実行後は docs/security.md の「Paper 更新」に従って backup、再起動、検証を行う

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
compose_file="$root_dir/compose.yml"
verify_script="$root_dir/scripts/verify-jars.sh"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $1" >&2
    exit 2
  fi
}

need curl
need jq
need perl
need docker

current_version="$(perl -ne 'print $1 if /^\s*VERSION:\s*"([^"]+)"/' "$compose_file")"
current_build="$(perl -ne 'print $1 if /^\s*PAPER_BUILD:\s*"([^"]+)"/' "$compose_file")"
current_sha256="$(perl -ne 'print $1 if /PAPER_EXPECTED_SHA256:-([0-9a-f]{64})/' "$verify_script")"
if [ -z "$current_version" ] || [ -z "$current_build" ] || [ -z "$current_sha256" ]; then
  echo "ERROR: compose.yml から VERSION / PAPER_BUILD を読み取れません" >&2
  exit 1
fi

version="${1:-$current_version}"
if [[ ! "$version" =~ ^[0-9][0-9A-Za-z._-]*$ ]]; then
  echo "ERROR: Paper version の形式が不正です: $version" >&2
  exit 2
fi

response="$(curl -fsS \
  -H "User-Agent: densanken-mc-setup/1.0 (paper pin update)" \
  "https://fill.papermc.io/v3/projects/paper/versions/$version/builds/latest")"

channel="$(jq -r '.channel' <<<"$response")"
build="$(jq -r '.id' <<<"$response")"
jar_name="$(jq -r '.downloads["server:default"].name' <<<"$response")"
sha256="$(jq -r '.downloads["server:default"].checksums.sha256' <<<"$response")"

if [ -z "$build" ] || [ "$build" = "null" ] || [ -z "$sha256" ] || [ "$sha256" = "null" ]; then
  echo "ERROR: Fill API の応答から build 情報を取得できません" >&2
  exit 1
fi
if [[ ! "$build" =~ ^[0-9]+$ ]] || [[ ! "$sha256" =~ ^[0-9a-f]{64}$ ]] || \
   [[ ! "$jar_name" =~ ^[0-9A-Za-z._+-]+\.jar$ ]]; then
  echo "ERROR: Fill API の応答に不正な build、jar 名、hash が含まれています" >&2
  exit 1
fi

if [ "$channel" != "STABLE" ]; then
  echo "ERROR: $version の最新 build $build は STABLE ではありません (channel: $channel)。更新を中止します" >&2
  exit 1
fi

if [ "$version" = "$current_version" ] && [ "$build" = "$current_build" ]; then
  echo "OK: すでに最新です: Paper $version Build #$build"
  exit 0
fi

echo "Paper $current_version Build #$current_build -> Paper $version Build #$build"

next_compose="$(mktemp "$compose_file.next.XXXXXX")"
next_verify="$(mktemp "$verify_script.next.XXXXXX")"
cleanup() {
  [ -z "$next_compose" ] || rm -f -- "$next_compose"
  [ -z "$next_verify" ] || rm -f -- "$next_verify"
}
trap cleanup EXIT HUP INT TERM
cp -p "$compose_file" "$next_compose"
cp -p "$verify_script" "$next_verify"

perl -pi -e "s/^(\\s*VERSION:\\s*)\"\\Q$current_version\\E\"/\${1}\"$version\"/" "$next_compose"
perl -pi -e "s/^(\\s*PAPER_BUILD:\\s*)\"\\Q$current_build\\E\"/\${1}\"$build\"/" "$next_compose"
perl -pi -e "s/paper-[0-9][^\"\\/]*?\\.jar/$jar_name/g" "$next_verify"
perl -pi -e "s/\\Q$current_sha256\\E/$sha256/g" "$next_verify"

if ! grep -q "PAPER_BUILD: \"$build\"" "$next_compose" || \
   ! grep -q "$sha256" "$next_verify" || \
   ! grep -q "$jar_name" "$next_verify" || \
   ! docker compose --env-file "$root_dir/.env.example" -f "$next_compose" config --quiet; then
  echo "ERROR: 更新候補の検証に失敗しました。元のファイルは変更していません" >&2
  exit 1
fi

mv "$next_compose" "$compose_file"
next_compose=""
mv "$next_verify" "$verify_script"
next_verify=""

echo "OK: compose.yml と scripts/verify-jars.sh を更新しました"
echo "次の手順: docs/security.md の Paper 更新手順に従って検証してください"
