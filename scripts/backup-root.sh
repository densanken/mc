#!/usr/bin/env sh
set -eu

# バックアップ保存先 (BACKUP_ROOT) を確認する
# --create を付けると、保存先とその下の world/coreprotect/quarantine を作成する

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
project_root="${MC_PROJECT_ROOT:-$(CDPATH= cd -- "$script_dir/.." && pwd)}"
project_root="$(CDPATH= cd -- "$project_root" && pwd -P)"
env_file="${MC_ENV_FILE:-$project_root/.env}"
mode="check"

case "${1:-}" in
  '') ;;
  --create) mode="create" ;;
  *)
    echo "usage: $0 [--create]" >&2
    exit 2
    ;;
esac

backup_root="${BACKUP_ROOT:-}"
if [ -z "$backup_root" ] && [ -r "$env_file" ]; then
  backup_root="$(awk -F= '$1 == "BACKUP_ROOT" { value = substr($0, index($0, "=") + 1) } END { print value }' "$env_file")"
fi
backup_root="${backup_root:-$HOME/mc-backups}"

physical_path() {
  candidate="$1"
  suffix=""
  while [ ! -e "$candidate" ]; do
    name="${candidate##*/}"
    suffix="/$name$suffix"
    candidate="${candidate%/*}"
    [ -n "$candidate" ] || candidate="/"
  done
  if [ ! -d "$candidate" ]; then
    return 1
  fi
  candidate="$(CDPATH= cd -- "$candidate" && pwd -P)" || return 1
  printf '%s%s\n' "${candidate%/}" "$suffix"
}

case "$backup_root" in
  /*) ;;
  *)
    echo "ERROR: BACKUP_ROOT は絶対パスで指定してください: $backup_root" >&2
    exit 1
    ;;
esac
case "/${backup_root#/}/" in
  *//* | */./* | */../*)
    echo "ERROR: BACKUP_ROOT は正規化した絶対パスで指定してください: $backup_root" >&2
    exit 1
    ;;
esac

physical_backup_root="$(physical_path "$backup_root")" || {
  echo "ERROR: BACKUP_ROOT の既存親ディレクトリを解決できません: $backup_root" >&2
  exit 1
}
case "$physical_backup_root" in
  / | "$project_root" | "$project_root"/*)
    echo "ERROR: BACKUP_ROOT はプロジェクトの外に配置してください: $backup_root" >&2
    exit 1
    ;;
esac

if [ "$mode" = create ]; then
  umask 077
  for directory in world coreprotect quarantine; do
    if [ -L "$backup_root/$directory" ]; then
      echo "ERROR: バックアップ保存先にシンボリックリンクは使用できません: $backup_root/$directory" >&2
      exit 1
    fi
  done
  mkdir -p "$backup_root/world" "$backup_root/coreprotect" "$backup_root/quarantine"
  for directory in world coreprotect quarantine; do
    physical_directory="$(physical_path "$backup_root/$directory")" || {
      echo "ERROR: バックアップ保存先の実パスを解決できません: $backup_root/$directory" >&2
      exit 1
    }
    case "$physical_directory" in
      "$project_root" | "$project_root"/*)
        echo "ERROR: バックアップ保存先はプロジェクトの外に配置してください: $backup_root/$directory" >&2
        exit 1
        ;;
    esac
  done
  chmod 0700 "$backup_root" "$backup_root/world" "$backup_root/coreprotect" "$backup_root/quarantine"
fi

for directory in world coreprotect quarantine; do
  if [ -L "$backup_root/$directory" ]; then
    echo "ERROR: バックアップ保存先にシンボリックリンクは使用できません: $backup_root/$directory" >&2
    exit 1
  fi
  if [ ! -d "$backup_root/$directory" ] || [ ! -w "$backup_root/$directory" ]; then
    echo "ERROR: バックアップ保存先へ書き込めません: $backup_root/$directory" >&2
    echo "       ./scripts/prepare-backup-storage.sh を実行してください" >&2
    exit 1
  fi
done

printf '%s\n' "$backup_root"
