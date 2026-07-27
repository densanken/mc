# mc

Paper を Docker Compose で運用する Minecraft サーバー構成です。
Discord アカウントとの連携と、許可した Discord サーバーへの所属をワールド参加の条件としています。

## サービス構成

Docker Compose で運用します。

- **minecraft**：Paper サーバー本体
- **backups**：ワールドの定期バックアップ
- **public-readiness**：Discord の参加制限と必須プラグインの有効状態を検査する一時サービス
- **playit**：Minecraft と Simple Voice Chat を外部へ中継する playit.gg エージェント

Paper、プラグイン、Docker イメージは、バージョンまたはダイジェストを構成ファイルへ固定しています。
更新手順は [jar と Docker イメージの検証](docs/security.md) を参照してください。

## ホストの要件

起動と管理には Docker Engine と Docker Compose が必要です。
更新用スクリプトは `curl`, `jq`, `perl` と、`sha1sum`, `sha256sum`, `sha512sum` または `shasum` を使用します。
管理対象の設定を反映するスクリプトは `perl` を使用します。
CoreProtect のバックアップと検査には `sqlite3` も必要です。
バックアップの検査は `gzip`, `tar`, `cp`, `cmp` も使用します。
RCON パスワードの生成には `openssl`、CoreProtect バックアップの排他制御には `flock` を使用します。
systemd timer のインストールには `runuser` も必要です。

リポジトリを配置したユーザーが Docker を操作できることを、次のコマンドで確認してください。
CoreProtect の systemd timer は、この運用ユーザーで Docker Compose を実行します。

```sh
docker compose version
docker info
```

## 初回セットアップ

Minecraft を初めて起動する前に、`.env` へホスト固有の値を設定する必要があります。

### `.env` と RCON パスワードを作成する

最初に、32バイト（256ビット）のランダムな RCON パスワードを生成して `.env` を作成してください。
`DISCORDSRV_TOKEN` と `PLAYIT_SECRET_KEY` は、それぞれの設定手順まで空のままにしてください。

```sh
umask 077
rcon_password="$(openssl rand -base64 32)" || exit 1
RCON_PASSWORD="$rcon_password" awk '
  /^RCON_PASSWORD=/ {
    print "RCON_PASSWORD=" ENVIRON["RCON_PASSWORD"]
    next
  }
  { print }
' .env.example > .env
unset rcon_password
chmod 600 .env
```

RCON パスワードが想定した長さの Base64 文字列として生成されたことを、値を表示せずに確認してください。
なにも表示されなければ問題ありません。

```sh
if [ "$(grep -c '^RCON_PASSWORD=' .env)" -ne 1 ] ||
  ! grep -Eq '^RCON_PASSWORD=[A-Za-z0-9+/]{43}=$' .env; then
  echo 'ERROR: .env の RCON_PASSWORD を生成できていません' >&2
  false
fi
```

### Minecraft の実行ユーザーを設定する

`.env` の `MINECRAFT_UID` と `MINECRAFT_GID` には、リポジトリを配置したホストユーザーの値を設定してください。
次のコマンドで値を確認できます。

```sh
id -u
id -g
```

### バックアップ保存先を準備する

`.env` の `BACKUP_ROOT` を設定しなかった場合、プロジェクトディレクトリ外の `$HOME/mc-backups` を使用します。
この保存先を変更する場合は、`.env` の `BACKUP_ROOT` にプロジェクトディレクトリ外の絶対パスを設定してください。
次のスクリプトは保存先を作成し、バックアップを書き込めることを確認します。

```sh
./scripts/prepare-backup-storage.sh
```

### Minecraft を初めて起動する

設定が終わったら、外部接続と定期バックアップを開始せずに Minecraft だけを起動してください。

```sh
docker compose up -d --no-deps --wait minecraft && \
  docker compose ps
docker compose logs --tail=160 minecraft
```

### DiscordGuildGate をビルドする

`minecraft` が `healthy` になったら依存 jar の取得は完了です。
Minecraft を停止してから DiscordGuildGate をビルドし、必須 jar を検証してください。

```sh
docker compose stop minecraft && \
  ./scripts/build-discord-guild-gate.sh && \
  ./scripts/verify-jars.sh && \
  docker compose up -d --no-deps --force-recreate --wait minecraft
docker compose logs --tail=160 minecraft
```

ログに `Done` が表示され、`minecraft` が再び `healthy` になってから、読み込まれたプラグインを確認してください。

```sh
docker compose ps
docker compose exec minecraft rcon-cli plugins
docker compose exec minecraft rcon-cli discordguildgate plugins
```

最後のコマンドが `DISABLED required-plugins=DiscordSRV` と応答すれば、Bot のトークンを設定する前の状態として正常です。

### Discord の参加制限と管理者権限を設定する

続いて、Discord と Minecraft の連携を次の順に設定してください。

1. [DiscordSRV の設定](docs/discordsrv.md)に従って、Discord の設定を Minecraft へ反映する
2. [権限設定](docs/permissions.md)に従って、管理者へ OP を付与する

DiscordSRV の設定手順に従い、参加制限が `READY`、必須プラグインが `ENABLED` になるまで `playit` を起動しないでください。

### バックアップを開始する

参加制限が `READY`、必須プラグインが `ENABLED` であることを確認してから、定期バックアップを開始して最初のバックアップを検査してください。

```sh
docker compose up -d --no-deps --wait minecraft && \
  ./scripts/coreprotect-backup-db.sh && \
  sleep 1 && \
  docker compose run --rm --no-deps backups now && \
  ./scripts/verify-backups.sh && \
  docker compose up -d --no-deps --wait backups && \
  sudo ./scripts/install-systemd-timers.sh && \
  systemctl is-active mc-coreprotect-db-backup.timer && \
  systemctl is-active mc-coreprotect-purge.timer
```

この時点では backups が未起動のため、最初のワールドの取得は[常駐する backups が動いていない場合](docs/operations.md#常駐する-backups-が動いていない場合)の形式になっています。
2つの timer が `active` になり、ワールドと CoreProtect DB のバックアップが検査を通ったことを確認してください。
保持する世代数は `compose.yml` の `PRUNE_BACKUPS_COUNT` と `scripts/coreprotect-backup-db.sh` の `KEEP_GENERATIONS` で管理しています。
CoreProtect はこの世代数に加え、保存済みの各ワールドより前に作成された直近の世代を保持します。

### playit で外部接続を確認する

参加制限が `READY`、必須プラグインが `ENABLED` であることを確認した後に、[playit.gg の設定](docs/playit.md)に従ってエージェントと2つのトンネルを設定してください。

LAN 外のクライアントから Minecraft と Simple Voice Chat へ接続でき、参加条件を満たさないアカウントが拒否されれば、初回セットアップは完了です。

設定途中で失敗した場合は、`docker compose stop playit` で playit を停止したまま問題を修正してください。
原因を修正したら、[DiscordSRV の「初回セットアップで参加制限を反映する」](docs/discordsrv.md#初回セットアップで参加制限を反映する)のコマンドを最初から再実行してください。

## 運用資料

- [日常運用と障害復旧](docs/operations.md)
- [DiscordSRV の設定](docs/discordsrv.md)
- [playit.gg の設定](docs/playit.md)
- [権限設定](docs/permissions.md)
- [管理対象の設定](docs/configuration.md)
- [参加者向け案内](docs/participant-guide.md)
- [jar と Docker イメージの検証](docs/security.md)
