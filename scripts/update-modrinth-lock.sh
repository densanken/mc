#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
projects_file="$root_dir/config/modrinth-projects.txt"
lock_file="$root_dir/config/modrinth-lock.tsv"
runtime_file="$(mktemp)"
next_lock="$(mktemp)"

cleanup() {
  rm -f "$runtime_file" "$next_lock"
}
trap cleanup EXIT

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $1" >&2
    exit 2
  fi
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

sha512_file() {
  local file="$1"
  if command -v sha512sum >/dev/null 2>&1; then
    sha512sum "$file" | awk '{print $1}'
  else
    shasum -a 512 "$file" | awk '{print $1}'
  fi
}

api_get() {
  local url="$1"
  local subject="${2:-$url}"
  local response_file http_status
  response_file="$(mktemp)"
  if ! http_status="$(curl -sS \
    --connect-timeout 10 \
    --max-time 30 \
    --retry 3 \
    --retry-connrefused \
    --retry-delay 1 \
    --retry-max-time 90 \
    -H "User-Agent: densanken-mc-setup/1.0 (modrinth lock update)" \
    -o "$response_file" \
    -w '%{http_code}' \
    "$url")"; then
    rm -f "$response_file"
    echo "ERROR: Modrinth API への接続に失敗しました: $subject ($url)" >&2
    return 1
  fi
  case "$http_status" in
    200)
      cat "$response_file"
      rm -f "$response_file"
      ;;
    404)
      rm -f "$response_file"
      echo "ERROR: Modrinth 管理対象として見つかりません (HTTP 404): $subject ($url)" >&2
      return 1
      ;;
    *)
      rm -f "$response_file"
      echo "ERROR: Modrinth API が HTTP $http_status を返しました: $subject ($url)" >&2
      return 1
      ;;
  esac
}

load_installed_jars() {
  shopt -s nullglob
  local jars=("$root_dir"/minecraft/plugins/*.jar)
  if [ "${#jars[@]}" -eq 0 ]; then
    echo "ERROR: minecraft/plugins に jar がありません。先に Minecraft を起動して Modrinth plugin を取得してください" >&2
    exit 1
  fi

  local jar
  for jar in "${jars[@]}"; do
    # DiscordGuildGate は repository 内の source から build するため、Modrinth lock の対象外
    if [ "$(basename "$jar")" = "DiscordGuildGate.jar" ]; then
      continue
    fi
    local filename hash response row
    filename="$(basename "$jar")"
    hash="$(sha512_file "$jar")"
    response="$(api_get \
      "https://api.modrinth.com/v2/version_file/$hash?algorithm=sha512" \
      "$filename")"
    row="$(jq -r --arg hash "$hash" '
      . as $version
      | first(.files[] | select(.hashes.sha512 == $hash)) as $file
      | select($file != null)
      | [$version.project_id, $version.version_number, $file.hashes.sha512, $file.filename]
      | @tsv
    ' <<<"$response")"
    if [ -z "$row" ]; then
      echo "ERROR: Modrinth response に一致する file hash がありません: $filename" >&2
      exit 1
    fi
    printf '%s\n' "$row" >> "$runtime_file"
  done
}

write_lock_header() {
  printf '# slug\tversion_number\tsha512\tfilename\n' > "$next_lock"
}

append_lock_entry() {
  local slug="$1"
  local expected_version="$2"
  local project_id match actual_version hash filename

  project_id="$(api_get "https://api.modrinth.com/v2/project/$slug" | jq -r '.id')"
  if [ -z "$project_id" ] || [ "$project_id" = "null" ]; then
    echo "ERROR: Modrinth project が見つかりません: $slug" >&2
    return 1
  fi

  match="$(awk -F '\t' -v project_id="$project_id" '$1 == project_id {print; exit}' "$runtime_file")"
  if [ -z "$match" ]; then
    echo "ERROR: config/modrinth-projects.txt の project に対応する jar がありません: $slug" >&2
    return 1
  fi

  actual_version="$(awk -F '\t' '{print $2}' <<<"$match")"
  hash="$(awk -F '\t' '{print $3}' <<<"$match")"
  filename="$(awk -F '\t' '{print $4}' <<<"$match")"

  if [ "$actual_version" != "$expected_version" ]; then
    echo "ERROR: $slug の jar version が config/modrinth-projects.txt と一致しません" >&2
    echo "  config: $expected_version" >&2
    echo "  jar:    $actual_version ($filename)" >&2
    return 1
  fi

  printf '%s\t%s\t%s\t%s\n' "$slug" "$actual_version" "$hash" "$filename" >> "$next_lock"
}

main() {
  need awk
  need curl
  need jq

  if [ ! -f "$projects_file" ]; then
    echo "ERROR: config/modrinth-projects.txt が見つかりません" >&2
    exit 2
  fi

  load_installed_jars
  write_lock_header

  local failures=0
  while IFS= read -r raw_line || [ -n "$raw_line" ]; do
    local line slug version
    line="${raw_line%%#*}"
    line="$(trim "$line")"
    [ -z "$line" ] && continue

    if [[ "$line" != *:* ]]; then
      echo "ERROR: version pin なしの行は lock 更新できません: $line" >&2
      failures=$((failures + 1))
      continue
    fi

    slug="${line%%:*}"
    version="${line#*:}"
    if [[ "$slug" == \?* ]]; then
      slug="${slug#\?}"
    fi

    if ! append_lock_entry "$slug" "$version"; then
      failures=$((failures + 1))
    fi
  done < "$projects_file"

  if [ "$failures" -gt 0 ]; then
    echo "ERROR: $failures 件の不一致があります。config/modrinth-lock.tsv は更新しません" >&2
    exit 1
  fi

  mv "$next_lock" "$lock_file"
  next_lock=""
  echo "OK: config/modrinth-lock.tsv を更新しました"

  # Modrinth plugin の更新後に DiscordGuildGate も再現 build し、local lock を更新する
  "$root_dir/scripts/update-discord-guild-gate-lock.sh"
}

main "$@"
