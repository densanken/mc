# DiscordSRV の設定

DiscordSRV は、Minecraft と Discord のチャット連携、および Minecraft アカウントとの連携に使用します。
DiscordGuildGate は、連携済みアカウントが許可した Discord サーバーのいずれかに参加していることを確認します。

## 準備する情報

設定を始める前に、次の情報を用意してください。

- Discord Bot のトークン
- ワールド参加を許可する Discord サーバーの ID
- Minecraft のチャットと連携する Discord チャンネルの ID
- アカウント連携時に自動付与する Discord ロールの ID
- Discord ロールも参加条件にする場合は、そのロールの ID

Discord Developer Portal で Application と Bot を作成し、`SERVER MEMBERS INTENT` と `MESSAGE CONTENT INTENT` を有効にしてください。
Bot は許可するすべての Discord サーバーに招待し、それ以外の Discord サーバーには招待しないでください。

連携チャンネルでは、Bot にチャンネルの表示、メッセージの送信、埋め込みリンク、Webhook の管理を許可してください。
連携時にロールを自動付与する場合は、Bot にロールの管理を許可し、対象ロールを Bot 自身の最高位ロールより下へ配置してください。
連携済みの Discord アカウントが Bot と共通する Discord サーバーへ参加しているかは、ロールを参加条件にしているかどうかにかかわらず、DiscordSRV が常に確認します。
この判定は DiscordGuildGate が停止しても働きます。

## Discord 設定の開始条件

先に [README の初回セットアップ](../README.md#初回セットアップ)に従い、Minecraft の初回起動、DiscordGuildGate のビルド、必須 jar の検証を完了してください。
README から続けて作業している場合は、これらの操作を繰り返さず、次の[Bot のトークンを設定する](#bot-のトークンを設定する)から進んでください。

## Bot のトークンを設定する

Discord Developer Portal で発行した Bot のトークンを、`.env` の `DISCORDSRV_TOKEN` に設定してください。
トークンは Compose secret として渡されます。
`minecraft/plugins/DiscordSRV/config.yml` の `BotToken` は変更しないでください。

```dotenv
DISCORDSRV_TOKEN=<Discord Bot のトークン>
```

## Discord サーバー、チャンネル、連携ロールを指定する

`.discordsrv.env.example` をコピーし、許可する Discord サーバーの ID と、Minecraft のチャットを転送する Discord チャンネルの ID を指定してください。
複数の Discord サーバー ID は空白を入れずにカンマで区切ってください。

```sh
umask 077
cp .discordsrv.env.example .discordsrv.env
chmod 600 .discordsrv.env
```

```dotenv
DISCORD_REQUIRED_GUILD_IDS=123456789012345678,234567890123456789
DISCORD_CHAT_CHANNEL_ID=345678901234567890
DISCORD_LINKED_ROLE_ID=456789012345678901
DISCORD_REQUIRED_ROLE_IDS=
DISCORD_REQUIRE_ALL_ROLES=false
```

`DISCORD_REQUIRED_GUILD_IDS` と `DISCORD_CHAT_CHANNEL_ID` には値を設定する必要があります。
Discord サーバー ID を複数指定した場合は、いずれか1つの Discord サーバーに参加していればワールドへ接続できます。

`DISCORD_LINKED_ROLE_ID` には、Minecraft アカウントとの連携が完了した Discord ユーザーへ付与するロール ID を1つ指定してください。
設定しなかった場合は、自動付与は行われません。
DiscordSRV は連携解除時に同じロールを削除しますが、設定前から連携済みのユーザーには遡って付与しません。

Discord ロールの有無もワールド接続の条件とする場合は、`DISCORD_REQUIRED_ROLE_IDS` にロール ID を指定してください。
複数のロール ID は空白を入れずにカンマで区切ってください。
`DISCORD_REQUIRE_ALL_ROLES` が `false` ならいずれか1つ、`true` ならすべてのロールを持っていることが参加条件になります。

```dotenv
DISCORD_REQUIRED_ROLE_IDS=456789012345678901,567890123456789012
DISCORD_REQUIRE_ALL_ROLES=false
```

## 初回セットアップで参加制限を反映する

この手順は、`playit` をまだ起動していない初回セットアップで実行します。
公開済みのサーバーで設定を変更する場合は、[参加条件と連携先を変更する](#参加条件と連携先を変更する)の手順に従ってください。

DiscordSRV と DiscordGuildGate の設定を反映し、Minecraft を再起動してください。

```sh
docker compose up -d --no-deps --force-recreate --wait minecraft && \
  ./scripts/configure-runtime-settings.sh && \
  docker compose up -d --no-deps --force-recreate --wait minecraft
docker compose logs --tail=160 minecraft
```

この手順を完了すると、DiscordSRV と DiscordGuildGate は次のように動作します。

- DiscordSRV の表示言語と標準メッセージ、進捗名を日本語へ切り替える
- Discord と未連携のプレイヤーを拒否する
- 未連携プレイヤーには招待 URL を表示せず、Discord の `/link` による連携方法を表示する
- `.discordsrv.env` の ID を DiscordGuildGate へ反映する
- アカウント連携時に、`DISCORD_LINKED_ROLE_ID` の Discord ロールを付与する
- Minecraft の `global` チャットを指定した Discord チャンネルへ接続する
- Minecraft のチャット、参加、退出、死亡、進捗を、DiscordGuildGate の Webhook で Discord へ送信する
- Discord から Minecraft へ転送するチャットには Discord ロールを表示しない
- Minecraft から Discord へ送る Webhook は、連携済みなら `Discordニックネーム（Minecraft名）` を表示名にし、未連携なら Minecraft 名だけを表示名にする
- Webhook のアイコンには、転送先 Discord サーバーのプロフィールアイコンを優先して使う
- Discord サーバーのプロフィールアイコンが未設定なら通常の Discord ユーザーアイコンを使い、Discord メンバー情報を取得できない場合は Minecraft プレイヤーのスキンを使う
- Discord から Minecraft へ転送するチャットは、連携済みなら `Minecraft名 (Discordニックネーム)` を表示名にする
- 入退室、死亡、進捗は timestamp 付きの Embed で送信し、進捗には日本語の説明も表示する
- DiscordSRV 標準の Discord サーバー参加判定を有効にする
- Discord のチャットから Minecraft のコンソールコマンドを実行できないようにする

再起動後に参加制限と必須プラグインを確認してください。

```sh
docker compose run --rm public-readiness
grep '^MinecraftDiscordAccountLinkedRoleNameToAddUserTo:' \
  minecraft/plugins/DiscordSRV/config.yml
```

出力に `READY` と必須プラグインの `ENABLED` が含まれるまで、playit を起動しないでください。
`grep` の出力に、`.discordsrv.env` へ指定したロール ID が表示されていることを確認してください。
参加制限が整っていない場合、`public-readiness` は `NOT_READY` に続けて理由を表示します。
`allowed-guild-ids-empty` は許可 ID が未設定、`discordsrv-not-ready` は DiscordSRV が未接続、`guild-unavailable:<Discord サーバー ID>` は Bot からその ID の Discord サーバーを参照できない状態です。

`public-readiness` は playit の起動前に実行する検査であり、起動後の DiscordSRV を継続監視しません。
運用中に DiscordSRV の切断や DiscordGuildGate の無効化を確認した場合は、`./scripts/check-status.sh` で状態を確認し、`docker compose stop playit` を実行してから原因を調査してください。

## 参加条件と連携先を変更する

公開済みのサーバーで許可する Discord サーバー、連携チャンネル、連携ロール、ロール条件を変更する場合は、先に playit を停止してから Maintenance モードを有効にする必要があります。

```sh
docker compose stop playit && \
  docker compose exec minecraft rcon-cli maintenance on && \
  ./scripts/configure-runtime-settings.sh && \
  docker compose up -d --no-deps --force-recreate --wait minecraft
```

連携チャンネルを変更した場合は、新しいチャンネルでも Bot にチャンネルの表示、メッセージの送信、埋め込みリンク、Webhook の管理を許可してください。
Minecraft が `healthy` になったら、[サーバーを公開へ戻す](operations.md#サーバーを公開へ戻す)の手順で状態を検査し、playit を起動してから Maintenance モードを解除してください。

`public-readiness` が失敗した場合は Maintenance モードを解除せず、`.discordsrv.env` の ID と Minecraft のログを確認してから、`./scripts/configure-runtime-settings.sh` を実行し直してください。
`allowed-guild-ids-empty`, `discordsrv-not-ready`, `guild-unavailable` の意味は[初回セットアップで参加制限を反映する](#初回セットアップで参加制限を反映する)に記載しています。

## DiscordSRV と DiscordGuildGate を更新する

プラグインとロックファイルの更新は、[jar と Docker イメージの検証](security.md)に従ってください。
更新後は[サーバーを公開へ戻す](operations.md#サーバーを公開へ戻す)の手順で参加制限と必須プラグインを確認してから、playit を起動してください。
