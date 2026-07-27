# 管理対象の設定

サーバーの再構築に必要な設定は、Compose、リポジトリ内の設定ファイル、ホスト固有の設定ファイルに分けて管理します。

## 設定元

| 対象 | 変更する場所 |
| --- | --- |
| `server.properties` | `compose.yml` |
| RCON パスワード | `.env` から作成する Compose secret |
| Minecraft と backups の実行 UID/GID | `.env` |
| ワールドと CoreProtect DB のバックアップ保存先 | `.env` の `BACKUP_ROOT` |
| Paper と Docker サービス | `compose.yml` |
| 導入するプラグイン | `config/modrinth-projects.txt` |
| TabTPS の表示 | `config/managed/TabTPS/` |
| Bukkit の既定権限 | `minecraft/permissions.yml` |
| DiscordSRV の表示、通知、参加制限 | `scripts/configure-runtime-settings.sh` |
| サーバーアイコン | `config/server-icon.png` |
| Discord Bot のトークン | `.env` から作成する Compose secret |
| 許可する Discord サーバー、連携チャンネル、連携時に付与するロール、任意の参加条件ロール ID | `.discordsrv.env` |
| Simple Voice Chat の外部接続先 | `minecraft/plugins/voicechat/voicechat-server.properties` |

`server.properties` は Minecraft コンテナの起動時に `compose.yml` から生成されます。
`minecraft/server.properties` は直接編集しないでください。
次の起動時に上書きされます。

## サーバー一覧の表示を変更する

Minecraft クライアントのサーバー一覧に表示する説明文は、`compose.yml` の `MOTD` で設定してください。
クライアントが保存するサーバー名は各参加者の設定であり、サーバー側からは変更できません。

`MOTD` では `§` から始まる色と装飾のコードを使用できます。

```yaml
MOTD: |-
  §aCCS Minecraft§r
  §7Survival Server
```

サーバーアイコンを設定する場合は、64×64ピクセルの PNG 画像を `config/server-icon.png` に配置してください。
新しいホストへ移行するときも、リポジトリとは別に保管した画像を `config/server-icon.png` へ配置してください。
Minecraft の起動時に、設定した画像がサーバーのデータディレクトリへ反映されます。
画像を削除して再起動すると、サーバーアイコンも解除されます。

公開済みのサーバーを変更する場合は、先に playit を停止してから Maintenance モードを有効にする必要があります。

```sh
docker compose stop playit && \
  docker compose exec minecraft rcon-cli maintenance on
```

MOTD またはアイコンを変更した場合は、Minecraft を再作成してください。

```sh
docker compose up -d --no-deps --force-recreate --wait minecraft
```

`docker compose ps` で Minecraft が `healthy` であることを確認してください。

公開済みのサーバーは、[サーバーを公開へ戻す](operations.md#サーバーを公開へ戻す)の手順で状態を検査し、playit を起動してから Maintenance モードを解除してください。
`public-readiness` が失敗した場合は Maintenance モードを解除せず、[DiscordSRV の設定](discordsrv.md)と Minecraft のログから原因を調査してください。

Maintenance モードを解除したら、Minecraft クライアントのサーバー一覧を更新してください。

## 管理対象の設定を反映する

### 初回セットアップ

Minecraft を起動して DiscordSRV と TabTPS の設定ファイルを生成し、管理対象の設定を反映してください。

```sh
docker compose up -d --no-deps --force-recreate --wait minecraft && \
  ./scripts/configure-runtime-settings.sh && \
  docker compose up -d --no-deps --force-recreate --wait minecraft
```

DiscordSRV には、[DiscordSRV の設定](discordsrv.md)で指定した参加制限、連携チャンネル、通知が反映されます。
Discord Bot のステータスには、現在オンラインのプレイヤー数が最大約1分間隔で表示されます。
TabTPS の管理対象ファイルは `config/managed/TabTPS/` の内容に置き換わり、Tab を開いている間はプレイヤー一覧の上部に TPS, MSPT, Ping が表示されます。
認証情報を含む設定ファイルは、権限 `0600` に変更されます。
コマンドがエラー終了した場合は、表示された不足ファイルまたは設定値を修正してから再実行してください。
DiscordSRV または TabTPS の更新後も同じ手順で設定を反映し直せます。

### 公開済みのサーバー

[参加条件と連携先を変更する](discordsrv.md#参加条件と連携先を変更する)の手順だけを実行してください。

## ホスト固有の設定

次の値はサーバーごとに異なります。

- `.env` の RCON パスワード、Discord Bot のトークン、playit.gg のシークレットキー、実行 UID/GID、バックアップ保存先
- `.discordsrv.env` の許可 Discord サーバー ID、連携チャンネル ID、連携時に付与するロール ID、任意の参加条件ロール ID
- `config/server-icon.png` のサーバーアイコン
- Simple Voice Chat の `voice_host`

`.env` と `.discordsrv.env` は、ホストの管理ユーザーだけが読める状態にしてください。
管理対象の認証情報を含むファイルは、次のスクリプトで権限を修正できます。

```sh
./scripts/harden-secret-permissions.sh
```

Discord の設定方法は [DiscordSRV の設定](discordsrv.md) を参照してください。
Simple Voice Chat の設定方法は [playit.gg の設定](playit.md) を参照してください。
