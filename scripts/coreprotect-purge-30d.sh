#!/usr/bin/env sh
set -eu

attempts="${COREPROTECT_PURGE_ATTEMPTS:-30}"
retry_seconds="${COREPROTECT_PURGE_RETRY_SECONDS:-10}"

case "$attempts" in
  '' | *[!0-9]*)
    echo "ERROR: purge の再試行回数と間隔は正の整数で指定してください" >&2
    exit 2
    ;;
esac
case "$attempts" in
  *[1-9]*) ;;
  *)
    echo "ERROR: purge の再試行回数と間隔は正の整数で指定してください" >&2
    exit 2
    ;;
esac
case "$retry_seconds" in
  '' | *[!0-9]*)
    echo "ERROR: purge の再試行回数と間隔は正の整数で指定してください" >&2
    exit 2
    ;;
esac
case "$retry_seconds" in
  *[1-9]*) ;;
  *)
    echo "ERROR: purge の再試行回数と間隔は正の整数で指定してください" >&2
    exit 2
    ;;
esac

attempt=1
while [ "$attempt" -le "$attempts" ]; do
  if docker compose exec -T --interactive=false minecraft rcon-cli "co purge t:30d"; then
    echo "OK: CoreProtect の30日以前の記録を削除しました"
    exit 0
  fi
  echo "WAIT: Minecraft の RCON を利用できません。purge を再試行します ($attempt/$attempts)" >&2
  if [ "$attempt" -lt "$attempts" ]; then
    sleep "$retry_seconds"
  fi
  attempt=$((attempt + 1))
done

echo "ERROR: CoreProtect purge を実行できませんでした" >&2
exit 1
