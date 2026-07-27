#!/usr/bin/env sh
set -eu

# world archive にはプレイヤーデータが含まれるため、host owner だけに読ませる
umask 077
/opt/mc/check-backup-storage.sh
exec /usr/bin/backup "$@"
