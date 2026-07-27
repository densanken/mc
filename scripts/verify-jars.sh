#!/usr/bin/env bash
set -euo pipefail

default_root_dir="$(cd "$(dirname "$0")/.." && pwd)"
root_dir="${MC_ROOT_DIR:-$default_root_dir}"
lock_file="${MODRINTH_LOCK_FILE:-$root_dir/config/modrinth-lock.tsv}"
gate_lock_file="${DISCORD_GUILD_GATE_LOCK_FILE:-$root_dir/config/discord-guild-gate-lock.tsv}"
paper_jar_name="${PAPER_JAR_NAME:-paper-26.1.2-74.jar}"
paper_expected_sha256="${PAPER_EXPECTED_SHA256:-1d70b1dab9cf4a6de615209a536f3a45a2186240253c428213ce2188ab95e5f7}"
verify_modrinth_api="${VERIFY_MODRINTH_API:-true}"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "FAIL: required command not found: $1" >&2
    exit 2
  fi
}

hash_file() {
  local algorithm="$1"
  local file="$2"
  case "$algorithm" in
    sha256)
      if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
      else
        shasum -a 256 "$file" | awk '{print $1}'
      fi
      ;;
    sha512)
      if command -v sha512sum >/dev/null 2>&1; then
        sha512sum "$file" | awk '{print $1}'
      else
        shasum -a 512 "$file" | awk '{print $1}'
      fi
      ;;
    *)
      echo "unsupported hash algorithm: $algorithm" >&2
      exit 2
      ;;
  esac
}

verify_paper() {
  local paper_jar="$root_dir/minecraft/$paper_jar_name"
  if [ ! -f "$paper_jar" ]; then
    echo "FAIL: required Paper jar not found: $paper_jar_name"
    return 1
  fi

  local actual
  actual="$(hash_file sha256 "$paper_jar")"
  if [ "$actual" = "$paper_expected_sha256" ]; then
    echo "OK: Paper $paper_jar_name sha256 matches official hash"
  else
    echo "FAIL: Paper $paper_jar_name sha256 mismatch"
    echo "  expected: $paper_expected_sha256"
    echo "  actual:   $actual"
    return 1
  fi
}

verify_modrinth_jar() {
  local slug="$1"
  local version="$2"
  local expected_hash="$3"
  local filename="$4"
  local jar="$root_dir/minecraft/plugins/$filename"

  if [ ! -f "$jar" ]; then
    echo "FAIL: required Modrinth jar not found: $filename ($slug $version)"
    return 1
  fi

  local hash
  hash="$(hash_file sha512 "$jar")"
  if [ "$hash" != "$expected_hash" ]; then
    echo "FAIL: $filename sha512 mismatch against config/modrinth-lock.tsv"
    echo "  expected: $expected_hash"
    echo "  actual:   $hash"
    return 1
  fi

  if [ "$verify_modrinth_api" != "true" ]; then
    echo "OK: $filename sha512 matches lock (Modrinth API check disabled)"
    return
  fi

  local response
  if ! response="$(curl -fs \
    --connect-timeout 5 \
    --max-time 20 \
    --retry 2 \
    --retry-delay 1 \
    --retry-all-errors \
    -H "User-Agent: densanken-mc-setup/1.0 (hash verification)" \
    "https://api.modrinth.com/v2/version_file/$hash?algorithm=sha512")"; then
    echo "FAIL: Modrinth did not recognize minecraft/plugins/$filename"
    return 1
  fi

  local api_project_id api_version api_filename
  api_project_id="$(jq -r '.project_id' <<<"$response")"
  api_version="$(jq -r '.version_number' <<<"$response")"
  api_filename="$(jq -r --arg hash "$hash" '.files[] | select(.hashes.sha512 == $hash) | .filename' \
    <<<"$response" | head -n 1)"
  if [ -z "$api_filename" ] || [ "$api_filename" != "$filename" ] || \
      [ "$api_version" != "$version" ]; then
    echo "FAIL: Modrinth metadata mismatch for $filename"
    echo "  lock version: $version"
    echo "  API version:  $api_version"
    echo "  API filename: $api_filename"
    return 1
  fi

  local expected_project_id
  expected_project_id="$(curl -fs \
    --connect-timeout 5 \
    --max-time 20 \
    --retry 2 \
    --retry-delay 1 \
    --retry-all-errors \
    -H "User-Agent: densanken-mc-setup/1.0 (hash verification)" \
    "https://api.modrinth.com/v2/project/$slug" | jq -r '.id')"
  if [ "$api_project_id" != "$expected_project_id" ]; then
    echo "FAIL: Modrinth project mismatch for $filename"
    return 1
  fi

  echo "OK: $filename sha512 matches lock and Modrinth metadata"
}

verify_gate_jar() {
  if [ ! -f "$gate_lock_file" ]; then
    echo "FAIL: DiscordGuildGate lock file not found: $gate_lock_file"
    return 1
  fi

  local entry_count lock_line expected_hash filename extra jar actual
  entry_count="$(awk -F '\t' '$0 !~ /^#/ && $0 !~ /^[[:space:]]*$/ {count++} END {print count + 0}' \
    "$gate_lock_file")"
  if [ "$entry_count" -ne 1 ]; then
    echo "FAIL: DiscordGuildGate lock must contain exactly one entry"
    return 1
  fi
  lock_line="$(awk -F '\t' 'NF == 2 && $1 !~ /^#/ {print; exit}' "$gate_lock_file")"
  expected_hash="$(awk -F '\t' '{print $1}' <<<"$lock_line")"
  filename="$(awk -F '\t' '{print $2}' <<<"$lock_line")"
  extra="$(awk -F '\t' '{print $3}' <<<"$lock_line")"
  if [[ ! "$expected_hash" =~ ^[0-9a-f]{64}$ ]] || \
      [ "$filename" != "DiscordGuildGate.jar" ] || [ -n "$extra" ]; then
    echo "FAIL: invalid DiscordGuildGate lock entry"
    return 1
  fi

  jar="$root_dir/minecraft/plugins/$filename"
  if [ ! -f "$jar" ]; then
    echo "FAIL: required local plugin jar not found: $filename"
    return 1
  fi
  actual="$(hash_file sha256 "$jar")"
  if [ "$actual" != "$expected_hash" ]; then
    echo "FAIL: $filename sha256 mismatch"
    echo "  expected: $expected_hash"
    echo "  actual:   $actual"
    return 1
  fi
  echo "OK: $filename sha256 matches local lock"
}

verify_lock_entries() {
  local failures=0 entries=0
  # loop 内の awk は lock file を読むだけで、書き込みは行わない
  # shellcheck disable=SC2094
  while IFS=$'\t' read -r slug version expected_hash filename extra || \
      [ -n "${slug:-}${version:-}${expected_hash:-}${filename:-}${extra:-}" ]; do
    [ -z "${slug:-}" ] && continue
    [[ "$slug" == \#* ]] && continue
    entries=$((entries + 1))
    if [ -n "${extra:-}" ] || [ -z "$version" ] || [ -z "$filename" ] || \
        [[ ! "$slug" =~ ^[a-z0-9][a-z0-9-]*$ ]] || \
        [[ ! "$version" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || \
        [[ ! "$expected_hash" =~ ^[0-9a-f]{128}$ ]] || \
        [[ ! "$filename" =~ ^[A-Za-z0-9][A-Za-z0-9._+()-]*\.jar$ ]]; then
      echo "FAIL: invalid Modrinth lock entry for $slug"
      failures=$((failures + 1))
      continue
    fi
    local duplicate_count duplicate_slug_count
    duplicate_count="$(awk -F '\t' -v filename="$filename" \
      '$1 !~ /^#/ && NF >= 4 && $4 == filename {count++} END {print count + 0}' "$lock_file")"
    if [ "$duplicate_count" -ne 1 ]; then
      echo "FAIL: duplicate filename in Modrinth lock: $filename"
      failures=$((failures + 1))
      continue
    fi
    duplicate_slug_count="$(awk -F '\t' -v slug="$slug" \
      '$1 !~ /^#/ && NF >= 4 && $1 == slug {count++} END {print count + 0}' "$lock_file")"
    if [ "$duplicate_slug_count" -ne 1 ]; then
      echo "FAIL: duplicate project slug in Modrinth lock: $slug"
      failures=$((failures + 1))
      continue
    fi
    verify_modrinth_jar "$slug" "$version" "$expected_hash" "$filename" || \
      failures=$((failures + 1))
  done < "$lock_file"

  if [ "$entries" -eq 0 ]; then
    echo "FAIL: Modrinth lock contains no entries"
    failures=$((failures + 1))
  fi
  [ "$failures" -eq 0 ]
}

verify_no_extra_jars() {
  local failures=0
  shopt -s nullglob
  local jars=("$root_dir"/minecraft/plugins/*.jar)
  local jar filename count
  for jar in "${jars[@]}"; do
    filename="$(basename "$jar")"
    if [ "$filename" = "DiscordGuildGate.jar" ]; then
      continue
    fi
    count="$(awk -F '\t' -v filename="$filename" \
      '$1 !~ /^#/ && NF >= 4 && $4 == filename {count++} END {print count + 0}' "$lock_file")"
    if [ "$count" -ne 1 ]; then
      echo "FAIL: untracked or duplicate plugin jar: $filename"
      failures=$((failures + 1))
    fi
  done
  [ "$failures" -eq 0 ]
}

main() {
  need awk
  if [ "$verify_modrinth_api" = "true" ]; then
    need curl
    need jq
  elif [ "$verify_modrinth_api" != "false" ]; then
    echo "FAIL: VERIFY_MODRINTH_API must be true or false" >&2
    exit 2
  fi

  if [ ! -f "$lock_file" ]; then
    echo "FAIL: lock file not found: $lock_file"
    exit 2
  fi

  local failures=0 result
  verify_paper || failures=$((failures + 1))
  verify_gate_jar || failures=$((failures + 1))

  set +e
  verify_lock_entries
  result=$?
  failures=$((failures + result))
  verify_no_extra_jars
  result=$?
  failures=$((failures + result))
  set -e

  if [ "$failures" -gt 0 ]; then
    echo "FAIL: $failures verification failure(s)"
    exit 1
  fi

  echo "OK: all required jars are present and verified"
}

main "$@"
