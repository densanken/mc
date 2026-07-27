#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

config="$fixture/config.yml"
runner="$fixture/set-language"
runner_log="$fixture/runner.log"

printf 'ForcedLanguage: none\n' > "$config"

cat > "$runner" <<'RUNNER'
#!/usr/bin/env sh
set -eu
printf 'called\n' >> "$DISCORDSRV_LANGUAGE_RUNNER_LOG"
perl -pi -e 's/^ForcedLanguage:.*/ForcedLanguage: "Japanese"/' "$1"
RUNNER
chmod +x "$runner"

DISCORDSRV_CONFIG_FILE="$config" \
DISCORDSRV_LANGUAGE_RUNNER="$runner" \
DISCORDSRV_LANGUAGE_RUNNER_LOG="$runner_log" \
  "$root_dir/scripts/configure-discordsrv-language.sh" >/dev/null

grep -q '^ForcedLanguage: "Japanese"$' "$config"
[ "$(wc -l < "$runner_log" | tr -d ' ')" = 1 ]

DISCORDSRV_CONFIG_FILE="$config" \
DISCORDSRV_LANGUAGE_RUNNER="$runner" \
DISCORDSRV_LANGUAGE_RUNNER_LOG="$runner_log" \
  "$root_dir/scripts/configure-discordsrv-language.sh" >/dev/null

[ "$(wc -l < "$runner_log" | tr -d ' ')" = 1 ]

printf 'ForcedLanguage: Japanese"\n' > "$config"
DISCORDSRV_CONFIG_FILE="$config" \
DISCORDSRV_LANGUAGE_RUNNER="$runner" \
DISCORDSRV_LANGUAGE_RUNNER_LOG="$runner_log" \
  "$root_dir/scripts/configure-discordsrv-language.sh" >/dev/null

[ "$(wc -l < "$runner_log" | tr -d ' ')" = 2 ]
grep -q '^ForcedLanguage: "Japanese"$' "$config"

printf 'OK: configure-discordsrv-language tests passed\n'
