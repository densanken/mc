# playit.gg の設定

playit.gg は、Minecraft と Simple Voice Chat を外部へ公開するために使用します。
先に Discord の参加制限を設定し、参加制限が `READY`、必須プラグインが `ENABLED` であることを確認してください。

## 接続経路

Minecraft と Simple Voice Chat には、それぞれ専用のトンネルが必要です。

| 用途 | 転送方式 | ローカル IP | ローカルポートの正となる設定 |
| --- | --- | --- | --- |
| Minecraft Java | TCP | `127.0.0.1` | `minecraft/server.properties` の `server-port` |
| Simple Voice Chat | UDP | `127.0.0.1` | `minecraft/plugins/voicechat/voicechat-server.properties` の `port` |

管理画面へ入力するポート番号は、次のコマンドで確認できます。
`minecraft/server.properties` は Minecraft の起動時に `compose.yml` から生成されるため、一度起動した後に確認してください。

```sh
grep '^server-port=' minecraft/server.properties
grep '^port=' minecraft/plugins/voicechat/voicechat-server.properties
```

`playit` は `minecraft` とネットワークを共有しています。
表の `127.0.0.1` はホストではなく、両サービスが共有するネットワーク内の Minecraft コンテナを指します。

`minecraft` コンテナを再作成すると、`playit` が共有していたネットワークも置き換わります。
公開済みのサーバーでは、先に `playit` を停止し、`minecraft` の再作成と参加制限の検査が終わってから `playit` も再作成する必要があります。
`minecraft` だけを再作成すると、既存の `playit` が古いネットワークを参照し、外部から接続できなくなる可能性があります。

```sh
docker compose stop playit && \
  docker compose up -d --no-deps --force-recreate --wait minecraft && \
  docker compose run --rm public-readiness && \
  docker compose --profile public up -d --no-deps --force-recreate --wait playit
docker compose logs --tail=120 playit
```

ログに `playit connected` が表示されれば、エージェントは再作成後のネットワークで playit.gg へ接続できています。
外部クライアントが実際に到達できるかは、この表示だけでは判断できません。
LAN 外のクライアントから Minecraft と Simple Voice Chat へ接続して確認してください。

この共有によって、playit エージェントは Minecraft と Simple Voice Chat だけでなく、同じネットワークで待ち受ける RCON にも到達できます。
playit.gg の管理画面には RCON ポートを転送するトンネルを作成しないでください。

## エージェントを登録する

playit.gg の管理画面で Docker エージェント用のシークレットキーを発行してください。
発行された値を `.env` の `PLAYIT_SECRET_KEY` に設定してください。

```dotenv
PLAYIT_SECRET_KEY=<playit.gg が発行したシークレットキー>
```

`.env` はホストの管理ユーザーだけが読める状態にしてください。

シークレットキーをログ、チャット、`compose.yml` へ記載しないでください。

## 参加制限と必須プラグインを確認してエージェントを起動する

playit を停止した状態で、Discord の参加制限と必須プラグインを確認してください。
参加制限が `READY`、必須プラグインが `ENABLED` であれば、playit エージェントを起動してください。

```sh
docker compose stop playit
docker compose run --rm public-readiness && \
  docker compose --profile public up -d --no-deps --force-recreate --wait playit
```

`READY` または `ENABLED` を確認できない場合は、[DiscordSRV の設定](discordsrv.md)と Minecraft のログを確認し、設定またはプラグインを修正してください。
起動済みの playit は、意図して停止しない限り Docker daemon の再起動後に自動で復旧しますが、参加制限と必須プラグインは再確認されません。
設定を変更した場合は、参加制限と必須プラグインを確認して playit を起動し直してください。

起動後はログに `playit connected` が表示されることを確認してください。

```sh
docker compose logs --tail=120 playit
```

`playit connected` が表示されず再試行が続く場合は playit を停止し、シークレットキーとホストの外向き通信を確認してください。
シークレットキーが空または不正な場合は、エージェントが終了します。
`.env` を修正してから、参加制限と必須プラグインを確認して playit を起動し直してください。

## トンネルを作成する

playit.gg の管理画面で Minecraft Java 用の TCP トンネルと、Simple Voice Chat 用の UDP トンネルを作成してください。
どちらの接続先にも、直前に起動した Docker エージェントを選択してください。
ローカル IP には `127.0.0.1` を指定してください。
ローカルポートは、作成前に[接続経路](#接続経路)のコマンドで `server-port` と `port` の値を確認し、表示された数値をそのまま指定してください。

Simple Voice Chat は Minecraft 本体とは別の UDP ポートを使用します。
Minecraft Java 用の TCP トンネルだけでは音声を送受信できません。

作成後は、管理画面に次のトンネルが存在しないことも確認してください。

- RCON のローカルポートを転送するトンネル
- 設定した覚えのない TCP または UDP トンネル
- 使用を終了した古いエージェントを接続先にするトンネル

## Simple Voice Chat の接続先を設定する

UDP トンネルが発行したホスト名とポートを、`minecraft/plugins/voicechat/voicechat-server.properties` の `voice_host` に設定してください。

```properties
bind_address=*
voice_host=<playit.gg が発行したホスト名>:<ポート>
```

`bind_address=*` は、Minecraft コンテナ内で UDP 接続を受け付けるための設定です。
変更後は Minecraft を再起動してください。

```sh
docker compose stop playit && \
  docker compose up -d --no-deps --force-recreate --wait minecraft && \
  docker compose run --rm public-readiness && \
  docker compose --profile public up -d --no-deps --force-recreate --wait playit
```

## 参照資料

- [playit-agent の Docker 実行方法](https://github.com/playit-cloud/playit-agent#docker)
- [playit.gg の Simple Voice Chat 設定](https://playit.gg/support/svc-minecraft/)
- [Docker Compose のネットワーク設定](https://docs.docker.com/compose/how-tos/networking/)
