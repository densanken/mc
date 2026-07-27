# 権限設定

この構成では権限管理プラグインを使用していません。
管理者の権限は `ops.json`、一般参加者へ追加する権限は `minecraft/permissions.yml` で管理します。
管理者と一般参加者の中間にあたる役割が必要になった場合は、LuckPerms などの権限管理プラグインを検討してください。

## 管理者権限

管理者へ OP を付与するには、次のコマンドを実行してください。

```sh
docker compose exec minecraft rcon-cli "op <Minecraft のユーザー名>"
```

OP には、既定で管理者向けとなっているプラグインの権限も付与されます。
この構成では、Maintenance, CoreProtect, spark, Simple Voice Chat, TabTPS の管理コマンドを使用できます。

管理者から OP を外す場合は、次のコマンドを実行してください。

```sh
docker compose exec minecraft rcon-cli "deop <Minecraft のユーザー名>"
```

## 一般参加者の権限

`minecraft/permissions.yml` では、すべての参加者へ `tabtps.defaultdisplay` を付与しています。

```yaml
densanken.player:
  description: 全参加者に付与する権限
  default: true
  children:
    tabtps.defaultdisplay: true
```

`permissions.yml` の変更は Minecraft の再起動後に反映されます。

### 初回セットアップ

外部公開を開始する前は、Minecraft を再起動し、`healthy` になるまで待ってください。

```sh
docker compose up -d --no-deps --force-recreate --wait minecraft
```

### 公開済みのサーバー

先に playit を停止してから Maintenance モードを有効にする必要があります。

```sh
docker compose stop playit && \
  docker compose exec minecraft rcon-cli maintenance on
```

Minecraft を再起動し、`healthy` になるまで待ってください。

```sh
docker compose up -d --no-deps --force-recreate --wait minecraft
```

続いて[サーバーを公開へ戻す](operations.md#サーバーを公開へ戻す)の手順で状態を検査し、playit を起動してから Maintenance モードを解除してください。
`public-readiness` が失敗した場合は Maintenance モードを解除せず、[DiscordSRV の設定](discordsrv.md)と Minecraft のログから原因を調査してください。
