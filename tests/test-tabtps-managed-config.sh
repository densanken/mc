#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
config="$root_dir/config/managed/TabTPS/display-configs/default.conf"
main_config="$root_dir/config/managed/TabTPS/main.conf"

tab_settings="$(
  awk '
    /^tab-settings \{$/ { in_tab_settings = 1 }
    in_tab_settings { print }
    in_tab_settings && /^}$/ { exit }
  ' "$config"
)"

require_setting() {
  setting="$1"
  if ! grep -Fqx "    $setting" <<<"$tab_settings"; then
    echo "FAIL: TabTPS tab-settings must contain $setting" >&2
    exit 1
  fi
}

require_setting 'allow=true'
require_setting 'enable-on-login=true'
require_setting 'header-modules="tps,mspt,ping"'
require_setting 'footer-modules=""'

if ! grep -Fqx 'update-checker=false' "$main_config"; then
  echo "FAIL: TabTPS update checker must be disabled for pinned updates" >&2
  exit 1
fi

echo "OK: TabTPS managed display settings passed"
