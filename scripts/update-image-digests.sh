#!/usr/bin/env bash
set -euo pipefail

# Compose image を、対応する tag の最新 manifest digest に更新する
# tag を pull して RepoDigest を取得し、compose.yml の image を書き換える
#
# 実行方法
#   ./scripts/update-image-digests.sh
#
# 実行後は docs/operations.md のアップデート手順に従って再作成と動作確認を行う

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
compose_file="$root_dir/compose.yml"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $1" >&2
    exit 2
  fi
}

need docker
need perl

next_compose="$(mktemp "$compose_file.next.XXXXXX")"
cleanup() {
  [ -z "$next_compose" ] || rm -f -- "$next_compose"
}
trap cleanup EXIT HUP INT TERM
cp -p "$compose_file" "$next_compose"

# image repository、digest を取得する tag、Compose に残す tag の対応
# Compose tag が不要な image は `-` を指定する
images=(
  "itzg/minecraft-server java25 java25"
  "itzg/mc-backup latest -"
  "ghcr.io/playit-cloud/playit-agent latest -"
)

changed=0
for entry in "${images[@]}"; do
  read -r repo pull_tag compose_tag <<< "$entry"
  image_ref="$repo"
  if [ "$compose_tag" != "-" ]; then
    image_ref="$repo:$compose_tag"
  fi

  if ! grep -Fq "image: $image_ref@sha256:" "$next_compose"; then
    echo "ERROR: compose.yml に $image_ref の digest 指定が見つかりません" >&2
    exit 1
  fi

  echo "pull: $repo:$pull_tag"
  docker pull --quiet "$repo:$pull_tag" >/dev/null

  digest="$(docker image inspect "$repo:$pull_tag" --format '{{range .RepoDigests}}{{println .}}{{end}}' \
    | grep "^$repo@sha256:" | head -n 1 | sed "s|^$repo@||")"
  if [ -z "$digest" ]; then
    echo "ERROR: $repo:$pull_tag の RepoDigest を取得できません" >&2
    exit 1
  fi

  current="$(perl -ne "while (m|image: \Q$image_ref\E\@(sha256:[0-9a-f]{64})|g) { print \$1, qq(\\n) }" "$next_compose")"
  all_current=1
  while IFS= read -r current_digest; do
    if [ "$current_digest" != "$digest" ]; then
      all_current=0
    fi
  done <<< "$current"
  if [ "$all_current" -eq 1 ]; then
    echo "OK: $image_ref は最新の digest です"
    continue
  fi

  perl -pi -e "s|(image: \Q$image_ref\E\@)sha256:[0-9a-f]{64}|\${1}$digest|" "$next_compose"
  echo "updated: $image_ref"
  echo "  old: $current"
  echo "  new: $digest"
  changed=1
done

if [ "$changed" -eq 1 ]; then
  if ! docker compose --env-file "$root_dir/.env.example" -f "$next_compose" config --quiet; then
    echo "ERROR: 更新候補の Compose 検証に失敗しました。元のファイルは変更していません" >&2
    exit 1
  fi
  mv "$next_compose" "$compose_file"
  next_compose=""
  echo "OK: compose.yml を更新しました"
  echo "次の手順: docs/security.md の Docker イメージ更新手順に従って検証してください"
else
  echo "OK: 変更はありません"
fi
