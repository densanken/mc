# jar と Docker イメージの検証

Paper、Modrinth から取得するプラグイン、DiscordGuildGate、Docker イメージは、意図しない更新を避けるために固定しています。

## 固定値の管理場所

| 対象 | バージョンまたは取得元 | ハッシュまたはダイジェスト |
| --- | --- | --- |
| Paper | `compose.yml` | `scripts/verify-jars.sh` |
| Modrinth のプラグイン | `config/modrinth-projects.txt` | `config/modrinth-lock.tsv` |
| DiscordGuildGate | `custom-plugins/DiscordGuildGate/` | `config/discord-guild-gate-lock.tsv` |
| Docker イメージ | 更新スクリプト内のタグ | `compose.yml` |
| DiscordGuildGate のビルダー | `scripts/build-discord-guild-gate.sh` | 同スクリプトのマニフェストダイジェスト |

## jar を検証する

Minecraft を起動して Paper とプラグインを取得した後、次のコマンドを実行してください。

```sh
./scripts/verify-jars.sh
```

スクリプトは次の条件を検査します。

- Paper jar の SHA-256 が記録済みの値と一致する
- Modrinth の全必須プラグインが1つずつ存在する
- Modrinth の jar の SHA-512、プロジェクト ID、バージョンがロックファイルと API の応答に一致する
- DiscordGuildGate.jar の SHA-256 がロックファイルと一致する
- ロックファイルにない jar や重複した jar が存在しない

Modrinth API へ問い合わせるため、実行時にはインターネット接続が必要です。
すべての項目が `OK` にならない場合は、Maintenance モードを解除せず、playit も起動しないでください。

読み込まれたプラグインは、Minecraft の起動後に次のコマンドで確認してください。

```sh
docker compose exec minecraft rcon-cli plugins
docker compose exec minecraft rcon-cli discordguildgate plugins
docker compose logs --tail=160 minecraft
```

jar の検証は既知の脆弱性を検出しないため、Docker イメージと依存ライブラリの脆弱性検査は別途必要です。

## 更新前の準備

Paper、プラグイン、Docker イメージのいずれを更新する場合も、先に外部接続を停止してバックアップを作成する必要があります。
停止するのは playit だけで、minecraft と backups は稼働したままです。
常駐する backups が稼働しているため、ワールドは[ワールドをバックアップする](operations.md#ワールドをバックアップする)と同じ `exec` の形式で取得します。

```sh
docker compose stop playit && \
  docker compose exec minecraft rcon-cli maintenance on && \
  ./scripts/coreprotect-backup-db.sh && \
  sleep 1 && \
  docker compose exec backups backup now && \
  ./scripts/verify-backups.sh
```

バックアップ検査に失敗した場合は、更新を始めないでください。
検査が通ったら、CoreProtect スクリプトが表示したパスと、今回作成したワールドアーカイブ名を控えてください。
`backup now` の出力にアーカイブ名が見当たらない場合は、上のコマンド列の直後に限り、保存先で最も新しいワールドアーカイブが今回作成したものです。

```sh
backup_root="$(./scripts/backup-root.sh)"
ls -1t "$backup_root/world"/minecraft-*.tar.gz | head -n 1
```

常駐する backups は稼働したままなので、`compose.yml` の `BACKUP_INTERVAL` に従う定期バックアップが後から加わると、このコマンドは今回作成したものとは別のワールドアーカイブを表示します。
`PAUSE_IF_NO_PLAYERS` によってプレイヤー不在時は保留されることもありますが、控える作業は後回しにしないでください。
Paper のバージョンを戻す場合は、控えた CoreProtect のアーカイブとワールドアーカイブを組み合わせて復元してください。

固定値を記録したファイルは、更新前の内容へ戻せる状態から始める必要があります。
更新スクリプトが書き換えるファイルに、未コミットの変更がないことを確認してください。

```sh
git status --short compose.yml config custom-plugins \
  scripts/verify-jars.sh scripts/build-discord-guild-gate.sh
```

差分が表示された場合は、その変更をコミットするか別の場所へ退避してから更新を始めてください。
整理後に同じ `git status` を実行し、なにも表示されなければ作業ツリーは整っています。

整理を終えた時点のコミットを、取り消しの基準として記録してください。

```sh
git rev-parse HEAD
```

このハッシュは取り消し手順の `before_update` に指定するため、更新作業が終わるまで手元へ残しておいてください。
変更を退避して作業ツリーを整えた場合、退避した内容はこのハッシュに含まれません。
取り消し後に必要な変更が失われないよう、退避した内容を戻す手順も控えておく必要があります。

1つの基準コミットから更新する対象は、Modrinth、DiscordGuildGate、Paper、Docker イメージのいずれか1カテゴリに限定してください。
別のカテゴリを更新するには、現在の更新を検証してコミットし、更新前の準備をやり直す必要があります。

## Modrinth のプラグインを更新する

`config/modrinth-projects.txt` の対象行を `<slug>:<version>` の形式で変更してください。
変更後に Minecraft を再起動することで、指定した jar がダウンロードされます。

```sh
docker compose up -d --no-deps --force-recreate --wait minecraft && \
  docker compose logs --tail=160 minecraft
```

Minecraft が起動したら依存 jar の取得は完了です。
Minecraft を停止してから、ダウンロード済みの jar を Modrinth API と照合し、ロックファイルを更新してください。

```sh
docker compose stop minecraft && \
  ./scripts/update-modrinth-lock.sh && \
  ./scripts/verify-jars.sh && \
  docker compose up -d --no-deps --force-recreate --wait minecraft && \
  docker compose exec minecraft rcon-cli discordguildgate plugins
```

`update-modrinth-lock.sh` は、設定したバージョンとダウンロード済み jar が一致しない場合にロックファイルを変更せず終了します。
ロックファイルの更新に成功すると、続けて `update-discord-guild-gate-lock.sh` が DiscordGuildGate を2回ビルドし、2つの jar が一致した場合だけ専用ロックファイルを更新します。

DiscordSRV または TabTPS を更新した場合は、管理対象の設定を反映してから Minecraft を再起動してください。

```sh
./scripts/configure-runtime-settings.sh && \
  docker compose up -d --no-deps --force-recreate --wait minecraft && \
  ./scripts/verify-jars.sh && \
  docker compose exec minecraft rcon-cli plugins && \
  docker compose exec minecraft rcon-cli discordguildgate plugins
```

jar の検証、Minecraft のログ、対象プラグインの動作を確認してから、[更新後に公開を再開する](#更新後に公開を再開する)へ進んでください。
検証に失敗した場合は playit を停止したまま、[Modrinth のプラグインの更新を取り消す](#modrinth-のプラグインの更新を取り消す)へ進んでください。

## DiscordGuildGate を更新する

DiscordGuildGate は、リポジトリ内のソースコードから Docker を使ってビルドします。
ビルダーは `scripts/build-discord-guild-gate.sh` でマニフェストダイジェストに固定しています。
`jar --date` でアーカイブ内のタイムスタンプも固定し、同じ入力から生成した2つの jar が一致した場合だけロックファイルを更新します。
Java のコンパイルでは `javac` の lint を有効にし、依存 jar の classfile 警告を除く警告をビルドエラーとして扱います。

```sh
docker compose stop minecraft && \
  ./scripts/update-discord-guild-gate-lock.sh && \
  docker compose up -d --no-deps --force-recreate --wait minecraft && \
  ./scripts/configure-runtime-settings.sh && \
  docker compose up -d --no-deps --force-recreate --wait minecraft && \
  ./scripts/verify-jars.sh && \
  docker compose exec minecraft rcon-cli discordguildgate status && \
  docker compose exec minecraft rcon-cli discordguildgate plugins
```

ビルダーは `images.flatt.tech` から取得しますが、管理主体とソースをこのリポジトリだけでは確認できません。
ビルド時は必要なソース、リソース、ライブラリだけを読み取り専用で渡し、ビルダーコンテナのネットワークを無効にしています。
ビルダーのダイジェストを更新する前に配布元を確認し、確認できない場合は由来を監査できる JDK 25 イメージへ置き換えてください。

ビルダーを更新した場合は、更新前後の jar のハッシュを比較してください。
ソース変更で説明できない差分があれば採用せず、[DiscordGuildGate の更新を取り消す](#discordguildgate-の更新を取り消す)へ進んでください。

再起動後は、DiscordGuildGate が読み込まれ、`discordguildgate status` が `READY`、`discordguildgate plugins` が `ENABLED` を返すことを確認してください。
Minecraft コンテナはホストへポートを公開しないため、アカウントによる接続確認は playit の起動後に行います。
ここまでを確認してから[更新後に公開を再開する](#更新後に公開を再開する)へ進み、許可条件の異なるアカウントで接続を確認してください。

## Paper を更新する

Paper のバージョン、ビルド、検証用 SHA-256 は、次のスクリプトでまとめて更新できます。
引数を省略すると現在のバージョンにある最新の安定ビルドを調べ、引数を指定するとそのバージョンにある最新の安定ビルドを調べます。
次の2行は代替手順です。
目的に合うどちらか一方だけを実行してください。

```sh
./scripts/update-paper-pin.sh
./scripts/update-paper-pin.sh "<バージョン>"
```

スクリプトは API 応答と更新候補の Compose を検証し、成功した場合だけ `compose.yml` と `scripts/verify-jars.sh` を置き換えます。
最新ビルドが安定版でない場合や候補の検証に失敗した場合は、どちらのファイルも変更しません。

Minecraft のバージョンを変更した場合は、Mojang 公式の日本語言語アセットから Discord 通知用の進捗名も更新してください。
引数を省略すると `compose.yml` の `VERSION` を使用します。
次の2行も代替手順です。
通常は、引数を省略した1行目だけを実行してください。

```sh
./scripts/update-advancement-translations.sh
./scripts/update-advancement-translations.sh "<バージョン>"
```

スクリプトは version metadata、asset index、`ja_jp.json` の SHA-1 を順に検証し、バニラ進捗のタイトルと説明だけを辞書へ書き出します。
検証に失敗した場合は既存の辞書を変更しません。

固定値を更新したら、Minecraft だけを再作成して Paper とライブラリを取得し直してください。

```sh
docker compose up -d --no-deps --wait minecraft && \
  docker compose logs --tail=160 minecraft && \
  ./scripts/update-advancement-translations.sh && \
  docker compose stop minecraft && \
  ./scripts/update-discord-guild-gate-lock.sh && \
  docker compose up -d --no-deps --force-recreate --wait minecraft && \
  ./scripts/verify-jars.sh && \
  docker compose exec minecraft rcon-cli plugins && \
  docker compose exec minecraft rcon-cli discordguildgate plugins
```

jar の検証、Minecraft のログ、プラグインの読み込みを確認してから、[更新後に公開を再開する](#更新後に公開を再開する)へ進んでください。
検証に失敗した場合は playit を停止したまま、[Paper の更新を取り消す](#paper-の更新を取り消す)へ進んでください。

## Docker イメージを更新する

`compose.yml` の Docker イメージはマニフェストダイジェストで固定しています。
次のスクリプトは、更新対象のタグを取得し、全イメージのダイジェストと更新候補の Compose を検証してから `compose.yml` を1回だけ置き換えます。

```sh
docker compose stop backups && \
  ./scripts/update-image-digests.sh && \
  docker compose --env-file .env.example config --quiet && \
  docker compose config --quiet
```

構成の検査後は、外部接続を停止したまま Minecraft と backups を再作成してください。

```sh
docker compose up -d --no-deps --wait minecraft && \
  docker compose ps && \
  docker compose logs --tail=160 minecraft && \
  ./scripts/verify-jars.sh && \
  docker compose exec minecraft rcon-cli discordguildgate plugins && \
  ./scripts/coreprotect-backup-db.sh && \
  sleep 1 && \
  docker compose run --rm --no-deps backups now && \
  ./scripts/verify-backups.sh && \
  docker compose up -d --no-deps --wait backups
```

節の冒頭で backups を停止しているため、ワールドの取得は[常駐する backups が動いていない場合](operations.md#常駐する-backups-が動いていない場合)の形式になっています。
Minecraft、必須 jar、バックアップを確認した後、[更新後に公開を再開する](#更新後に公開を再開する)へ進んでください。
更新後に問題がある場合は playit を停止したまま、[Docker イメージの更新を取り消す](#docker-イメージの更新を取り消す)へ進んでください。

## 更新後に公開を再開する

対象サービスの検証に成功したら、[サーバーを公開へ戻す](operations.md#サーバーを公開へ戻す)の手順で状態を検査し、playit を起動してから Maintenance モードを解除してください。

`public-readiness` が失敗した場合は Maintenance モードを解除せず、[更新を取り消す](#更新を取り消す)へ進むか、Minecraft と DiscordSRV のログから原因を調査してください。

## 更新を取り消す

更新後の検証に失敗した場合は、playit を停止し Maintenance モードを有効にしたまま、対象ごとの手順で更新前の内容へ戻してください。
最初に、戻す基準を `before_update` に設定してください。
更新をまだコミットしていない場合は `HEAD` が更新前の内容です。

```sh
before_update="HEAD"
```

更新をコミット済みの場合は、[更新前の準備](#更新前の準備)で控えたハッシュを設定してください。

```sh
before_update="<更新前のコミットのハッシュ>"
```

`git restore <ファイル>` はインデックスの内容で作業ツリーを上書きするため、`git add` 済みの更新は警告なく残ります。
以降の手順では `--staged --worktree` を付けて、インデックスと作業ツリーの両方を `$before_update` の内容へ戻します。
戻した状態で検証に成功したら、[更新後に公開を再開する](#更新後に公開を再開する)へ進んでください。

`compose.yml` は Paper の固定値と Docker イメージのダイジェストを両方記録し、Paper の jar 名と SHA-256 は `scripts/verify-jars.sh` にあります。
更新前の準備でカテゴリを分けていない場合は、対象別の取り消し手順を実行しないでください。
Minecraft を停止したまま、差分のある全カテゴリの入力を `$before_update` へ戻し、控えたワールドと CoreProtect の組み合わせを[最新バックアップから復元する](operations.md#最新バックアップから復元する)の手順で復元してください。

### Modrinth のプラグインの更新を取り消す

戻したバージョンの jar は、Minecraft の再作成で取得し直します。
Modrinth のロックを戻した後は、`update-discord-guild-gate-lock.sh` で DiscordGuildGate を作り直してください。
ロックファイルだけを戻すと、`minecraft/plugins/DiscordGuildGate.jar` が記録と一致しません。

```sh
git restore --source="$before_update" --staged --worktree \
  config/modrinth-projects.txt config/modrinth-lock.tsv \
  config/discord-guild-gate-lock.tsv
```

DiscordSRV または TabTPS の設定を反映していた場合は、Minecraft の再作成前に `./scripts/configure-runtime-settings.sh` を実行してください。
更新したプラグインのリリースノートまたは更新ログに DB または設定形式の移行が示されている場合は、次の起動手順を実行しないでください。
`git restore` で入力を戻した状態のまま、控えたワールドと CoreProtect の組み合わせを[最新バックアップから復元する](operations.md#最新バックアップから復元する)の手順で復元してください。

```sh
docker compose up -d --no-deps --force-recreate --wait minecraft && \
  docker compose logs --tail=160 minecraft && \
  docker compose stop minecraft && \
  ./scripts/update-discord-guild-gate-lock.sh && \
  git diff --exit-code "$before_update" -- \
    config/discord-guild-gate-lock.tsv && \
  ./scripts/verify-jars.sh && \
  docker compose up -d --no-deps --force-recreate --wait minecraft && \
  docker compose exec minecraft rcon-cli plugins && \
  docker compose exec minecraft rcon-cli discordguildgate plugins
```

`verify-jars.sh` のすべての項目が `OK` になり、必須プラグインが `ENABLED` に戻ったことを確認してください。
`git diff` がなにも表示せず成功すれば、DiscordGuildGate も更新前と同じ jar に戻っています。
旧版での起動に失敗した場合は再試行せず、控えたワールドと CoreProtect の組み合わせを[最新バックアップから復元する](operations.md#最新バックアップから復元する)の手順で復元してください。

Paper API または DiscordSRV の jar を1つに絞れない場合は、対象を分けて確認してください。

```sh
find minecraft/libraries/io/papermc/paper/paper-api \
  -type f -name 'paper-api-*.jar' -print
find minecraft/plugins -maxdepth 1 -type f -name 'DiscordSRV-*.jar' -print
```

Paper API が複数ある場合は Minecraft のライブラリ取得ログを調査してください。
DiscordSRV が複数ある場合は、更新後に残った jar を通常の配置先から外し、`docker compose up` から始まる起動手順をやり直してください。

### DiscordGuildGate の更新を取り消す

ビルダー、ソース、テスト、リソース、ロックファイルを更新前へ戻し、jar を作り直してください。
`git restore` は未追跡ファイルを削除しないため、追加した未追跡ファイルが残っている間はビルドへ進みません。

```sh
git restore --source="$before_update" --staged --worktree \
  scripts/build-discord-guild-gate.sh \
  custom-plugins/DiscordGuildGate \
  config/discord-guild-gate-lock.tsv && \
  test -z "$(git ls-files --others --exclude-standard -- \
    custom-plugins/DiscordGuildGate)" && \
  docker compose stop minecraft && \
  ./scripts/update-discord-guild-gate-lock.sh && \
  git diff --exit-code "$before_update" -- \
    scripts/build-discord-guild-gate.sh \
    custom-plugins/DiscordGuildGate \
    config/discord-guild-gate-lock.tsv && \
  docker compose up -d --no-deps --force-recreate --wait minecraft && \
  ./scripts/verify-jars.sh && \
  docker compose exec minecraft rcon-cli discordguildgate status
```

未追跡ファイルの検査で停止した場合は、`git status --short custom-plugins/DiscordGuildGate` で対象を確認し、更新前から存在しなかったファイルを別の場所へ退避してください。
`git diff` がなにも表示せず成功すれば、更新前の入力から同じ jar を再現できています。
差分が表示された場合は Minecraft を再作成せず、ビルド環境の差分を調査してください。

### Paper の更新を取り消す

`update-paper-pin.sh` が置き換えた固定値と、`update-advancement-translations.sh` が書き出した進捗名の辞書を戻してください。
先に `compose.yml` の差分を確認し、Minecraft の `VERSION` を変更したかを判定してください。

```sh
git diff "$before_update" -- compose.yml
```

固定値、進捗名の辞書、DiscordGuildGate のロックファイルを更新前へ戻してください。

```sh
git restore --source="$before_update" --staged --worktree \
  compose.yml scripts/verify-jars.sh \
  custom-plugins/DiscordGuildGate/src/main/resources/advancements-ja_jp.properties \
  config/discord-guild-gate-lock.tsv
```

Minecraft の `VERSION` を変更していた場合は、まだ Minecraft を起動しないでください。
新しいバージョンで開いたワールドは、プレイヤーが参加していなくても自動的に更新され、古いバージョンへの読み戻しはサポートされません。
[最新バックアップから復元する](operations.md#最新バックアップから復元する)に従い、更新前の準備で作成したワールドと、そのワールドより前の CoreProtect DB を復元してください。
復元手順が更新前の Paper とプラグインを取得し直すため、この節の残りのコマンドは実行しないでください。

Minecraft の `VERSION` を変更していない場合は、更新前の Paper API を取得して DiscordGuildGate を作り直してください。

```sh
docker compose up -d --no-deps --force-recreate --wait minecraft && \
  docker compose logs --tail=160 minecraft && \
  docker compose stop minecraft && \
  ./scripts/update-discord-guild-gate-lock.sh && \
  git diff --exit-code "$before_update" -- \
    config/discord-guild-gate-lock.tsv && \
  docker compose up -d --no-deps --force-recreate --wait minecraft && \
  ./scripts/verify-jars.sh && \
  docker compose exec minecraft rcon-cli plugins
```

`git diff` がなにも表示せず成功すれば、更新前の Paper API で同じ jar を再現できています。

### Docker イメージの更新を取り消す

`compose.yml` は Paper の固定値も記録しているため、対になる `scripts/verify-jars.sh` も同時に戻してください。
片方だけを戻すと、`verify-jars.sh` が稼働中と異なるバージョンの jar を検査して `OK` を返します。
Paper も同じ作業ツリーで更新していた場合は、先に[Paper の更新を取り消す](#paper-の更新を取り消す)を実行してください。
Minecraft のバージョンを下げる前に、更新前のワールドを復元する必要があるためです。

```sh
git restore --source="$before_update" --staged --worktree \
  compose.yml scripts/verify-jars.sh && \
  docker compose --env-file .env.example config --quiet && \
  docker compose config --quiet
```

新しいイメージのログに `minecraft` データの移行が示されている場合は、古いイメージを起動せず、控えたワールドと CoreProtect の組み合わせを[最新バックアップから復元する](operations.md#最新バックアップから復元する)の手順で復元してください。
データ移行がない場合は、古いイメージでサービスを起動してください。

```sh
docker compose up -d --no-deps --wait minecraft && \
  docker compose ps && \
  docker compose logs --tail=160 minecraft && \
  ./scripts/verify-jars.sh && \
  docker compose up -d --no-deps --wait backups
```

`minecraft` と `backups` が `healthy` になり、jar の検証に成功したことを確認してください。

## リポジトリの変更を検証する

Compose、シェルスクリプト、検証処理を変更した場合は、ローカルテストを実行してください。

```sh
./scripts/test.sh
```

このスクリプトは、シェルスクリプトの構文と、jar 検証、`public-readiness`、Discord 設定、CoreProtect の処理、バックアップ検査、バックアップ保存先の fixture テストを実行し、あわせて Compose 構成を確認します。
実行には Docker Compose と `sqlite3` が必要です。

GitHub Actions の `.github/workflows/validate.yml` は、ShellCheck、設定ファイルと実行時データの混入、ローカルテストを検査します。
統合テストでは、Minecraft の起動、DiscordGuildGate の再現ビルドと Paper への読み込み、必須 jar の検証、プロジェクト外へのワールドバックアップを実行します。
失敗時は Minecraft の状態とログを出力し、成功または失敗にかかわらずコンテナを停止します。
ローカルテストが成功しても、CI の完了前に更新を公開しないでください。

## シークレットを表示せずに構成を検査する

RCON パスワードは `.env` を元に Compose secret を作成し、minecraft, backups, public-readiness へファイルとして渡します。
コンテナへ渡す環境変数は `RCON_PASSWORD_FILE` のパスだけで、RCON パスワードそのものは含みません。

`docker compose config` の通常出力には `.env` から展開した値が含まれる場合があります。
構成の妥当性だけを確認する場合は、出力を抑止する次の形式を使用してください。

```sh
docker compose config --quiet
```
