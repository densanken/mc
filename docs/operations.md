# サーバー運用

Minecraft サーバーの日常操作、バックアップ、障害復旧の手順です。
初回セットアップは [README](../README.md) を参照してください。

## サービスを起動して状態を確認する

起動済みの minecraft, backups, playit は、意図して停止しない限り Docker daemon の再起動後に自動で復旧します。
`docker compose down` の実行後など、コンテナが存在しない状態から起動する場合は、Minecraft と backups を起動してから参加制限と必須プラグインを確認し、playit を起動してください。

```sh
docker compose up -d --wait minecraft backups && \
  ./scripts/check-status.sh && \
  docker compose run --rm public-readiness && \
  docker compose --profile public up -d --no-deps --force-recreate --wait playit
```

`check-status.sh` が失敗した場合は playit を起動せず、表示された項目を解決してください。
CoreProtect の定期処理に関する項目には、[CoreProtect の項目を解決する](#coreprotect-の項目を解決する)に手順があります。

起動後は playit のログを確認してください。

```sh
docker compose logs --tail=120 playit
```

`playit connected` が表示されない場合や再接続を繰り返している場合は、`docker compose stop playit` を実行してログを調査してください。

日常の状態確認にも `./scripts/check-status.sh` を実行してください。

```sh
./scripts/check-status.sh
```

スクリプトは最初にサービス一覧と Minecraft の直近のログを表示します。
この2つは失敗の判定に使わないため、内容は運用者が読んで確認してください。

続いて、失敗した件数を数える検査に入ります。
最初に、保守停止のマーカーである `.coreprotect-maintenance` が残っていないことを検査します。
次に minecraft が稼働して `healthy` であること、必須プラグインがすべて有効であること、backups が稼働して `healthy` であることを検査します。
backups の healthcheck が確認するのは、`BACKUP_ROOT/world` に置いた保存先の目印である sentinel ファイルと書き込みだけで、`BACKUP_ROOT/coreprotect` は対象外です。
CoreProtect については、2つの systemd timer が `active` で対応する2つの service が失敗状態でないこと、更新時刻が鮮度の上限以内に収まるアーカイブがあることを検査します。
この鮮度は `find -mmin` によるファイルの更新時刻で判定するため、保存先のアーカイブをコピーしたり更新時刻を書き換えたりすると、検査結果は実際の取得時刻からずれます。
playit が稼働していれば、Discord の参加制限が `READY` であることも検査します。
playit が停止していればこの検査は行わず、「OK: playit は稼働していません（非公開）」を表示します。
最後に `verify-backups.sh` を実行し、保存済みのワールドと CoreProtect のアーカイブを検査します。
このバックアップ検査にはホストの `sqlite3` が必要です。

これらの検査のいずれかに失敗するとエラー終了し、末尾に件数を表示します。
表示された項目を確認し、対象サービスのログまたは systemd journal を調査してください。
backups の保存先 healthcheck の失敗内容はログに出力されないため、`docker inspect --format '{{json .State.Health}}' minecraft-backups` で確認してください。
sentinel を確認できないと表示されるのは、`BACKUP_ROOT/world` に sentinel ファイルがない場合と、シンボリックリンクや通常ファイル以外になっている場合、内容が想定と異なる場合です。
sentinel が存在しないだけであれば、`./scripts/prepare-backup-storage.sh` が保存先と sentinel を作り直します。
sentinel が残っていて内容や種類が想定と異なる場合、`prepare-backup-storage.sh` はその sentinel を上書きせずエラー終了するため、`BACKUP_ROOT` の指定先が意図した保存先かを確認し、その sentinel を手で片付けてから実行し直してください。

Discord の参加制限は次のコマンドで確認できます。

```sh
docker compose exec minecraft rcon-cli discordguildgate status
```

`READY` 以外の場合、`docker compose stop playit` を実行してから Minecraft と DiscordSRV のログを調査してください。
サービスごとのログは次のコマンドで確認できます。

```sh
docker compose logs --tail=160 minecraft
docker compose logs --tail=160 backups
docker compose logs --tail=160 playit
```

### CoreProtect の項目を解決する

`check-status.sh` が CoreProtect の定期処理について報告する項目は4種類あります。
保存済みのアーカイブ自体が検査に失敗する項目は、[バックアップを検査する](#バックアップを検査する)を参照してください。
`.coreprotect-maintenance` が残っている間は、生成される unit の `ConditionPathExists` によって、timer が `active` でも CoreProtect のバックアップと purge のどちらも実行されません。
マーカーはホストの再起動をまたいで残るため、再起動で timer が `active` に戻っていてもバックアップが1件も作られない状態が続きます。

復元や取り消しの作業を実行している最中は、この節を適用しないでください。
[最新バックアップから復元する](#最新バックアップから復元する)と[復元を取り消す](#復元を取り消す)は、手順の中でマーカーを作って timer を停止します。
その状態は手順を終えるまで意図したものなので、実行中の手順の続きへ戻ってください。
[プロジェクトディレクトリだけを失った場合](#プロジェクトディレクトリだけを失った場合)も、旧環境の unit を無効化したまま進める経路なので対象外です。

「ERROR: 過去 N 分以内の CoreProtect バックアップがありません」は、保存先にある CoreProtect アーカイブの更新時刻がどれも鮮度の上限より古い状態です。
N には上限が入り、その値は `scripts/check-status.sh` の `COREPROTECT_BACKUP_MAX_AGE_MINUTES` を正とします。
timer が停止していた間や、ホストを上限より長く停止した直後に発生します。
マーカーが残っている間もバックアップは作られないため、この項目だけが出ているかどうかで対処が変わります。
他の項目を解決したあと、この項目だけが残ったら、バックアップを取得してから再検査してください。

```sh
./scripts/coreprotect-backup-db.sh && \
  ./scripts/check-status.sh
```

この `coreprotect-backup-db.sh` は、ロックに関するエラーで終了することがあります。
「ERROR: CoreProtect DB backup はすでに実行中か lock が不正です」は、timer からの実行と重なっている状態なので、少し待って実行し直してください。
「ERROR: CoreProtect DB backup の lock が通常ファイルではありません」は、メッセージの末尾に出るパスがシンボリックリンクやディレクトリになっている状態です。
スクリプトは通常ファイル以外を拒否するだけで中身には触れないため、`ls -ld <パス>` でそのパスの種類とリンク先を確認してください。
ディレクトリであれば中身も確認し、失っても構わないものだけを残した状態にしてから、そのパスを片付けて実行し直してください。

「ERROR: CoreProtect の定期処理が保守のため停止したままです」や「ERROR: <unit 名> が active ではありません」が出ている場合は、定期処理そのものが止まっています。
timer が `active` でない原因は、復元作業の中断、unit の未作成、手動での停止など複数あります。
再開する前に、CoreProtect 以外の項目を先に解決してください。
Minecraft が停止していると、timer の再開後に purge が失敗して再実行を繰り返し、Minecraft が起動した時点で運用者の確認を経ずに履歴を削除します。
必須プラグインが無効な場合は purge が空振りし、履歴を削除しないまま成功として記録されます。
常駐する backups が停止したままだと backups の検査に失敗するため、最後の再検査でも失敗件数は 0 になりません。

timer より先に検査済みのバックアップを用意するのは、timer の再開で purge がその場で動く場合に備えるためです。
[CoreProtect の古い記録を削除する](#coreprotect-の古い記録を削除する)は検査済みの CoreProtect バックアップがあることを前提にしており、先に用意しておけばマーカーの有無にかかわらずその前提を満たせます。
最初に CoreProtect のバックアップを取得し、保存済みのアーカイブを検査してください。

```sh
./scripts/coreprotect-backup-db.sh && \
  ./scripts/verify-backups.sh
```

どちらかが失敗したら、timer を起動せずに原因を解決してください。
`coreprotect-backup-db.sh` は、ホストに `sqlite3` または `flock` がない場合、CoreProtect の DB が見つからない場合、実行中のロックを取得できない場合、保持数を適用できない壊れたアーカイブがある場合などに失敗します。
いずれも原因を示すメッセージを表示するので、その内容を確認してください。
`verify-backups.sh` は、保存済みのアーカイブに問題がある場合のほか、アーカイブが1件もない場合と、`gzip`, `tar`, `sqlite3`, `cp`, `cmp` のいずれかがホストにない場合にも失敗します。
アーカイブの問題であれば、[バックアップを検査する](#バックアップを検査する)の `mv` と `chmod 600` で失敗したアーカイブを退避し、[ワールドをバックアップする](#ワールドをバックアップする)の順序で取り直してから、この手順をやり直してください。

次に unit の状態を確認してください。

```sh
systemctl is-enabled mc-coreprotect-db-backup.timer mc-coreprotect-purge.timer
```

`enabled` 以外が表示された場合と、unit が見つからないというエラーが出た場合は、[systemd timer を設定する](#systemd-timer-を設定する)で unit を作り直してください。
作り直すと timer は起動しますがマーカーは残るため、そのあとはマーカーを削除する手順から続けてください。

両方が `enabled` であれば timer を起動し、`active` になったことを確認してください。

```sh
sudo systemctl start mc-coreprotect-db-backup.timer mc-coreprotect-purge.timer && \
  systemctl is-active mc-coreprotect-db-backup.timer && \
  systemctl is-active mc-coreprotect-purge.timer
```

マーカーが残っている場合、この起動で逃した実行が1回だけトリガーされますが、生成される unit の `ConditionPathExists` によって skip されます。
トリガーされた記録は残るため、そのあとマーカーを削除しても purge が改めて走ることはありません。
マーカーを先に消してから timer を起動すると、この吸収が効きません。
purge はプレイヤーの少ない時間帯に設定してありますが、この場合は公開中に走るため、一時的に負荷が上がります。
マーカーは、timer が `active` になったことを確認してから削除してください。

マーカーが無い状態から起動する場合は、この吸収がそもそも働かず、逃した purge がその場で走ります。
ここまでの手順で検査済みのバックアップを用意しているため履歴は失われませんが、公開中は一時的に負荷が上がります。

最後にマーカーを削除して再検査してください。
マーカーが無い状態では `rm` がなにもしないため、そのまま同じコマンドを実行できます。

```sh
sudo rm -f .coreprotect-maintenance && \
  ./scripts/check-status.sh
```

再検査が保存先の変更と重なると、走査の途中で消えたアーカイブによって失敗することがあります。
もう一度実行して同じ失敗が出なければ、走査中の削除と重なっただけなので復旧できています。
同じアーカイブで再現する場合は、そのアーカイブ自体の問題として[バックアップを検査する](#バックアップを検査する)の手順で退避してください。

「ERROR: <unit 名> が失敗状態です」は、直前の実行が失敗したまま記録されている状態です。
journal で原因を確認してください。

```sh
journalctl -u mc-coreprotect-db-backup.service -u mc-coreprotect-purge.service
```

原因を解決したら、記録されている失敗状態を解除してください。

```sh
sudo systemctl reset-failed \
  mc-coreprotect-db-backup.service \
  mc-coreprotect-purge.service
```

どの項目も、解決したら `./scripts/check-status.sh` を再実行して確認してください。
playit を稼働させたまま日常の状態確認から来た場合は、再検査の成功で復旧は完了です。
playit を停止している場合は、[サーバーを公開へ戻す](#サーバーを公開へ戻す)で `public-readiness` を実行してから playit を起動してください。

## サーバー負荷を確認する

spark のコマンドは Minecraft コンテナのコンソールへ送信します。
RCON では応答を取得できない場合があるため、`mc-send-to-console` を使用してください。

```sh
minecraft_uid="$(awk -F= '$1 == "MINECRAFT_UID" { print $2 }' .env)"
docker compose exec --user "$minecraft_uid" minecraft mc-send-to-console spark tps
docker compose exec --user "$minecraft_uid" minecraft mc-send-to-console spark health --memory
unset minecraft_uid
```

TabTPS の `/mspt` は RCON から確認できます。

```sh
docker compose exec minecraft rcon-cli mspt
```

一般参加者には、Tab キーを押している間、プレイヤー一覧の上部に TPS, MSPT, Ping を表示します。
Ping は、表示しているプレイヤー自身の通信遅延です。
権限と表示範囲は [権限設定](permissions.md) を参照してください。

## Maintenance モードを切り替える

更新、復元、外部接続の確認中は Maintenance モードを有効にしてください。

```sh
docker compose exec minecraft rcon-cli maintenance status
docker compose exec minecraft rcon-cli maintenance on
docker compose exec minecraft rcon-cli maintenance off
```

作業に失敗した場合は Maintenance モードを解除せず、必要に応じて `docker compose stop playit` で外部接続も停止してください。

## サーバーを停止する

計画停止では、ワールドを保存してからサービスを停止してください。

```sh
docker compose exec minecraft rcon-cli save-all
docker compose stop playit
docker compose stop backups minecraft
```

コンテナの強制停止は、ワールド保存とバックアップ処理を中断する可能性があります。
強制停止は使用しないでください。

## Docker ログを確認する

各サービスは Docker の `local` ロギングドライバーを使用します。
ログの上限と保持数は `compose.yml` の `x-container-logging` で管理しています。

ローテーション後のログも `docker compose logs` から確認できます。
長期保存が必要なログは、Docker のログ保存先とは別の監視基盤へ転送してください。

## ワールドをバックアップする

`backups` サービスは、`compose.yml` の `BACKUP_INTERVAL` に従ってワールドをバックアップします。
ワールドと CoreProtect DB の保存先は `.env` の `BACKUP_ROOT`、保持数は `compose.yml` の `PRUNE_BACKUPS_COUNT` と CoreProtect のバックアップスクリプトで確認してください。
既定の保存先は `$HOME/mc-backups` です。
保存先をプロジェクト外に置くことで、プロジェクトディレクトリを削除しても復元候補が残ります。

`PAUSE_IF_NO_PLAYERS` が有効な場合、バックアップ完了時にプレイヤーがいなければ、次回の予約をプレイヤーが参加するまで保留します。
保留されるのは定期実行だけです。
`backup now` で作成する手動バックアップは、プレイヤーが不在でも実行されます。

ワールドと CoreProtect は1つのスナップショットとして同時に取得できないため、手動取得では CoreProtect、ワールドの順を守ってください。
CoreProtect を先に取得すると、その直後に作成するワールドの復元候補として保持されます。
任意の時点でバックアップを作成するには、Minecraft と backups が稼働している状態で次のコマンドを実行してください。

```sh
./scripts/coreprotect-backup-db.sh && \
  sleep 1 && \
  docker compose exec backups backup now
```

1秒待つのは、ファイル名の時刻を確実に分け、CoreProtect がワールドより前の世代だと判定できるようにするためです。

両方のバックアップに成功したら、`backup now` がその場に表示した出力で、`save-off`、`save-all`、アーカイブ作成、`save-on` が成功したことを確認してください。
`docker compose exec` は同じコンテナ内の別プロセスを起こす形式で、その出力は exec セッションへ返ります。
Docker のログストリームが取り込むのは常駐プロセスの出力だけなので、手動バックアップの結果は `docker compose logs backups` に現れません。
`docker compose logs backups` に出るのは、常駐する `backups` が記録した内容だけです。
`BACKUP_INTERVAL` に従う定期バックアップの記録に加えて、`start-backups.sh` が起動時に実行する保存先検査の失敗もそこに入ります。
`compose.yml` で `BACKUP_ON_STARTUP` を無効にし `PAUSE_IF_NO_PLAYERS` を有効にしている場合、プレイヤーが不在の間は定期バックアップの記録が1件も出ないこともあります。

順序を逆にした場合の結果は、そのワールドより前の CoreProtect アーカイブが残っているかどうかで変わります。
初回セットアップのように1つも残っていない状態では、`verify-backups.sh` がそのワールドアーカイブを `FAIL` にします。
`check-status.sh` も同時に失敗するため、失敗したアーカイブを `BACKUP_ROOT/quarantine` へ退避するか削除するまで検査は毎回失敗します。
解決するまで playit を起動しないでください。
ワールドアーカイブがこの1つしかない場合は、退避すると0件になって別の理由で失敗します。
[バックアップを検査する](#バックアップを検査する)の `mv` と `chmod 600` で失敗したアーカイブを退避してから、この節の順序でバックアップを取り直してください。
常駐する backups がまだ起動していなければ、この節のコマンドのうち `docker compose exec backups backup now` を `docker compose run --rm --no-deps backups now` に置き換えて実行し、そのあと `docker compose up -d --no-deps --wait backups` で常駐を開始してください。

古い世代が残っている状態では、`verify-backups.sh` は保存済みの CoreProtect 全体からワールドより前のアーカイブを探して合格させるため、検査は通ります。
ただし、そのワールドと組み合わせられる CoreProtect は手動取得より前の古い世代だけになるため、復元すると直近の履歴が失われます。

ワールドのアーカイブからは、再取得できる jar、キャッシュ、ログ、一時ファイルを除外しています。
認証情報と稼働中のデータベースは、次の理由で除外しています。

- `server.properties` と `.rcon-cli.*`：RCON パスワードを含み、起動時に再生成される
- `permissions.yml`：復元先に配置した現在の権限設定を使用し、過去の設定で上書きしない
- `plugins/DiscordSRV/config.yml`、言語別の `*.config.yml`、`.token`：Bot のトークンを含む可能性があり、設定は復元後に再反映する
- `plugins/CoreProtect/database.db*`：稼働中の SQLite DB は専用スクリプトで取得する

実際の除外対象は `compose.yml` の `backups.environment.EXCLUDES` を確認してください。

使用中の容量とファイル数は、次のコマンドで確認できます。

```sh
backup_root="$(./scripts/backup-root.sh)"
du -sh "$backup_root/world" "$backup_root/coreprotect"
find "$backup_root/world" -maxdepth 1 -type f | wc -l
find "$backup_root/coreprotect" -maxdepth 1 -type f | wc -l
df -h "$backup_root"
```

`BACKUP_ROOT` が Minecraft と同じディスクにある場合、プロジェクトの誤削除には耐えられても、ディスク故障には耐えられません。
ホストまたはディスクの故障に備えるには、別ディスクまたは外部ストレージへの複製が必要です。

### 常駐する backups が動いていない場合

常駐する backups が動いていないと `exec` は使用できません。
`docker compose run --rm --no-deps backups now` で使い捨てのコンテナを起こしてワールドを取得したあと、`docker compose up -d --no-deps --wait backups` で常駐を開始してください。
`--no-deps` を付けるのは、`backups` が `depends_on` で `minecraft` の `service_healthy` を要求するためです。
付けずに実行すると、停止中の `minecraft` の起動まで巻き込みます。
この形式でも出力は実行した端末へ返るため、確認方法は `exec` と同じです。

## CoreProtect をバックアップする

CoreProtect の SQLite DB は、オンラインバックアップ機能を使って取得します。

```sh
./scripts/coreprotect-backup-db.sh
```

スクリプトは同時実行を拒否し、SQLite の `integrity_check` と `gzip -t` に成功したアーカイブだけを `BACKUP_ROOT/coreprotect` へ保存します。
処理に失敗した場合は一時ファイルを削除して実行中ロックを解放し、壊れたアーカイブを最終ファイル名で残しません。

最新の保持数とは別に、保存済みの各ワールドアーカイブ `minecraft-YYYYMMDD-HHMMSS.tar.gz` または `minecraft-YYYYMMDD-HHMMSS-<連番>.tar.gz` について、その時刻より前に作成された直近の CoreProtect アーカイブを復元用に保持します。
ワールドが自動削除されると対応する保護も解除され、次回の CoreProtect バックアップ時に通常の保持数から外れたアーカイブが削除されます。
保持数を適用するとき、ファイル名から作成時刻を判定できないワールドアーカイブには対応する CoreProtect 世代を追加保持せず、警告して処理を続けます。
作成時刻を判定できないワールドアーカイブは `verify-backups.sh` の検査に失敗するため、復元候補として使用できません。

ワールドと CoreProtect のファイル名は、どちらも `Asia/Tokyo` の作成時刻を使用します。
同一秒に作成された2つのアーカイブは順序を判定できないため、復元用の組み合わせとして扱いません。
手動取得で守る順序と、順序を誤った場合の結果は[ワールドをバックアップする](#ワールドをバックアップする)を参照してください。

保持数を一時的に変更する場合は `KEEP_GENERATIONS` を指定できます。

```sh
KEEP_GENERATIONS="<保持する世代数>" ./scripts/coreprotect-backup-db.sh
```

## バックアップを検査する

保存済みのワールドと CoreProtect のアーカイブを次のコマンドで検査してください。

```sh
./scripts/verify-backups.sh
```

ワールドのアーカイブには gzip と tar の検査を行い、`world/level.dat` が一意の通常ファイルで gzip 展開できることを確認します。
RCON、Discord Bot、DiscordSRV のトークンを含み得る config と、CoreProtect の稼働中 DB が含まれていないことも検査します。
CoreProtect のアーカイブでは、展開後の SQLite DB に `PRAGMA integrity_check` を実行し、user table の存在を検査します。
ワールドごとに、その作成時刻より前の CoreProtect アーカイブが少なくとも1つ存在することも確認します。
作成時刻をファイル名から判定できないワールドアーカイブは、対応関係を保証できないため検査に失敗します。

検査に失敗したアーカイブは、通常の復元候補から外してください。
そのうえで削除せずに調査する場合は、`BACKUP_ROOT/quarantine` へ移動し、ホストの管理ユーザーだけが読める状態にしてください。

```sh
backup_root="$(./scripts/backup-root.sh)"
failed_archive="<検査に失敗したアーカイブのパス>"
mv "$failed_archive" "$backup_root/quarantine/" && \
  chmod 600 "$backup_root/quarantine/$(basename "$failed_archive")"
```

`verify-backups.sh` は `BACKUP_ROOT/world` と `BACKUP_ROOT/coreprotect` だけを走査するため、退避したアーカイブは検査対象から外れます。
退避のたびに再検査し、失敗が残っていないことを確認してください。

```sh
./scripts/verify-backups.sh
```

すべて `OK` になるまで、残りの失敗したアーカイブを同じ手順で退避してください。
ただし退避の結果ワールドまたは CoreProtect のアーカイブが0件になると、`verify-backups.sh` は `FAIL: world backup archive not found` などを出して失敗し続けます。
この状態からは退避を繰り返しても復旧しないため、[ワールドをバックアップする](#ワールドをバックアップする)の順序でバックアップを取り直してから再検査してください。

機密ファイルを含むアーカイブが見つかった場合は、RCON パスワードと Discord Bot のトークンを変更してください。

## 最新バックアップから復元する

復元中は playit を停止してください。
稼働中のデータは手順6の退避ディレクトリで保全します。
復元直前に新しいバックアップを作ると、そのアーカイブが復元対象の候補に混ざるため、この手順では作成しないでください。

1. playit を停止する

   ```sh
   docker compose stop playit
   ```

2. Maintenance モードを有効にする

   ```sh
   docker compose exec minecraft rcon-cli maintenance on
   ```

   Minecraft が停止済みまたは応答不能でコマンドが失敗しても、playit が停止していれば復元を続行できます。

3. CoreProtect の定期処理を一時停止する

   `.coreprotect-maintenance` はホストの再起動後も一時停止を維持するマーカーファイルです。

   ```sh
   sudo install -m 0600 /dev/null .coreprotect-maintenance && \
     test -f .coreprotect-maintenance && \
     sudo systemctl stop mc-coreprotect-db-backup.timer mc-coreprotect-purge.timer
   systemctl is-active mc-coreprotect-db-backup.service
   systemctl is-active mc-coreprotect-purge.service
   ```

   timer の停止は発火済みの service を中断しません。
   最後の `is-active` で両方の service が `inactive` または `failed` と表示され、実行中でないことを確認してから次へ進んでください。

4. 定期バックアップと Minecraft を停止する

   ```sh
   docker compose stop backups minecraft
   ```

5. 停止後のバックアップを検査する

   ```sh
   ./scripts/verify-backups.sh
   ```

   検査に失敗した場合は `minecraft` ディレクトリを変更せず、失敗したアーカイブを通常の復元候補から外してください。

6. 現在のデータディレクトリを退避し、空の復元先を作成する

   ```sh
   restore_guard="minecraft.before-restore.$(date +%Y%m%d-%H%M%S)"
   test -d minecraft && \
     test ! -e "$restore_guard" && \
     umask 077 && \
     mv minecraft "$restore_guard" && \
     chmod 700 "$restore_guard" && \
     mkdir minecraft && \
     printf '退避先: %s\n' "$restore_guard"
   ```

   退避先にはワールドと認証情報が含まれます。
   復元完了まで削除しないでください。
   いずれかのコマンドが失敗した場合は、`minecraft` と `$restore_guard` の状態を確認し、両方の役割が確定するまで次へ進まないでください。

7. 検査済みのワールドアーカイブを復元する

   `BACKUP_ROOT/world` から復元するアーカイブを1つ選び、空の `minecraft` ディレクトリへ展開してください。
   自動的に最新ファイルを選ばず、手順5で検査を通したアーカイブのパスを指定してください。

   ```sh
   backup_root="$(./scripts/backup-root.sh)"
   restore_archive="$backup_root/world/<検査済みのワールドアーカイブ>.tar.gz"
   test -f "$restore_archive" && \
     test -z "$(find minecraft -mindepth 1 -print -quit)" && \
     tar -xzf "$restore_archive" -C minecraft/ && \
     test -f minecraft/world/level.dat
   ```

   `tar` の展開または `level.dat` の確認に失敗した場合は、部分的に展開されたファイルが残らないよう `minecraft` を空にしてから、別のアーカイブで再試行してください。

8. 現在の権限設定を退避先から戻す

   ```sh
   restore_guard="<手順6で表示された退避先>"
   install -m 0644 "$restore_guard/permissions.yml" minecraft/permissions.yml
   ```

9. CoreProtect の履歴を復元する

   ワールドのアーカイブより前に作成した CoreProtect のアーカイブを選びます。
   ワールドより新しい CoreProtect DB は、復元後のワールドに存在しない操作を含むため、絶対に使用しないでください。
   同一秒のアーカイブは順序を判定できないため使用できません。
   条件に合う CoreProtect のアーカイブがない場合は、対応する CoreProtect アーカイブが残っている別のワールドを選んでください。
   `verify-backups.sh` が検査できる組み合わせがない場合は、この手順を続行できません。

   ```sh
   backup_root="$(./scripts/backup-root.sh)"
   coreprotect_archive="$backup_root/coreprotect/<CoreProtect のアーカイブ>.db.gz"
   restored_db="minecraft/plugins/CoreProtect/database.db.restore"
   test -f "$coreprotect_archive" && \
     mkdir -p minecraft/plugins/CoreProtect && \
     test ! -e "$restored_db" && \
     gzip -dc "$coreprotect_archive" > "$restored_db" && \
     integrity="$(sqlite3 "$restored_db" 'PRAGMA integrity_check;')" && \
     test "$integrity" = "ok" && \
     chmod 600 "$restored_db" && \
     mv "$restored_db" minecraft/plugins/CoreProtect/database.db
   ```

   失敗して `database.db.restore` が残った場合は、そのファイルを復元候補として使わず、原因を確認してから削除して手順9をやり直してください。

10. DiscordSRV のホスト固有設定を確認する

    `.env` の Bot トークンと `.discordsrv.env` の Discord サーバー ID、連携チャンネル ID を確認してください。
    別ホストへの復元や Bot のトークンのローテーション後は、[DiscordSRV の設定](discordsrv.md)に従って新しい値を設定してください。

11. 外部へ公開せずに Minecraft を起動する

    アーカイブには jar を含まないため、Paper とプラグインは起動時に再取得されます。

    ```sh
    docker compose up -d --no-deps --force-recreate --wait minecraft
    ```

    Minecraft が起動したらログを確認してください。

    ```sh
    docker compose logs --tail=160 minecraft
    ```

12. DiscordGuildGate と管理対象の設定を復元する

    ```sh
    docker compose stop minecraft && \
      ./scripts/build-discord-guild-gate.sh && \
      ./scripts/verify-jars.sh && \
      docker compose up -d --no-deps --force-recreate --wait minecraft && \
      ./scripts/configure-runtime-settings.sh && \
      docker compose up -d --no-deps --force-recreate --wait minecraft && \
      docker compose ps
    ```

    `minecraft` が `healthy` になったら、DiscordGuildGate の状態を確認してください。

    ```sh
    docker compose exec minecraft rcon-cli discordguildgate status
    ```

    `READY` 以外の応答では playit を起動しないでください。

13. Maintenance モードを有効にし、バックアップを再開する

    ```sh
    docker compose exec minecraft rcon-cli maintenance on && \
      docker compose up -d --no-deps --wait minecraft && \
      ./scripts/coreprotect-backup-db.sh && \
      sleep 1 && \
      docker compose run --rm --no-deps backups now && \
      ./scripts/verify-backups.sh && \
      docker compose up -d --no-deps --wait backups && \
      sudo systemctl start mc-coreprotect-db-backup.timer mc-coreprotect-purge.timer && \
      systemctl is-active mc-coreprotect-db-backup.timer && \
      systemctl is-active mc-coreprotect-purge.timer && \
      sudo rm -f .coreprotect-maintenance
    ```

    手順4で backups を停止しているため、ワールドの取得は[常駐する backups が動いていない場合](#常駐する-backups-が動いていない場合)の形式になっています。
    `verify-backups.sh` が失敗すると後続のコマンドは実行されず、常駐する `backups` と CoreProtect の timer も再開しません。
    timer の再開に失敗した場合は `.coreprotect-maintenance` が残ります。
    playit も起動しないでください。
    表示されたエラーを解決してから手順13を再実行してください。
    同じエラーが解決しない場合は、復元したアーカイブ自体に問題があります。

復元したデータで Minecraft が稼働し、バックアップと CoreProtect の定期処理を再開できたら、[サーバーを公開へ戻す](#サーバーを公開へ戻す)へ進んでください。
復元したワールドや履歴の内容に問題が見つかった場合は、公開へ戻さず[復元を取り消す](#復元を取り消す)を実行してください。

## サーバーを公開へ戻す

更新、設定変更、復元のいずれの作業でも、Minecraft が `healthy` になり、変更した内容を確認してから実行してください。

[サービスを起動して状態を確認する](#サービスを起動して状態を確認する)と同じ検査を実行してください。

```sh
./scripts/check-status.sh
```

playit を停止したまま実行するため、Discord の参加制限は検査されません。
成功時の末尾行は playit の停止中でも「参加制限」を含むため、この行を参加制限の確認とみなさないでください。
参加制限を確認するのは、後続の `docker compose run --rm public-readiness` です。

検査に失敗した場合は、表示された項目を解決するまで playit を起動しないでください。
CoreProtect の定期処理に関する項目には、[CoreProtect の項目を解決する](#coreprotect-の項目を解決する)に手順があります。
`check-status.sh` は保存済みのアーカイブをすべて検査するため、世代数によっては時間がかかります。

検査に成功したら playit を起動してください。

```sh
docker compose run --rm public-readiness && \
  docker compose --profile public up -d --no-deps --force-recreate --wait playit
```

`public-readiness` が失敗すると playit は起動しません。
Maintenance モードは解除せず、Minecraft と DiscordSRV のログを調査してください。

playit のログを確認してください。

```sh
docker compose logs --tail=120 playit
```

`playit connected` が表示されたら Maintenance モードを解除し、参加を再開してください。

```sh
docker compose exec minecraft rcon-cli maintenance off
```

`playit connected` が表示されない場合や再接続を繰り返している場合は、Maintenance モードを解除せず、playit を停止してログを調査してください。

## 復元を取り消す

復元したデータに問題があった場合に、退避前の状態へ戻す手順です。
[最新バックアップから復元する](#最新バックアップから復元する)の手順6で作成した退避先が残っている間だけ実行できます。

1. 外部接続と CoreProtect の定期処理を停止する

   ```sh
   docker compose stop playit && \
     sudo install -m 0600 /dev/null .coreprotect-maintenance && \
     test -f .coreprotect-maintenance && \
     sudo systemctl stop mc-coreprotect-db-backup.timer mc-coreprotect-purge.timer
   systemctl is-active mc-coreprotect-db-backup.service
   systemctl is-active mc-coreprotect-purge.service
   ```

   最後の `is-active` で両方の service が `inactive` または `failed` と表示され、実行中でないことを確認してから次へ進んでください。

2. 復元したデータと退避先を入れ替える

   ```sh
   restore_guard="<手順6で表示された退避先>"
   failed_restore="minecraft.before-restore.failed.$(date +%Y%m%d-%H%M%S)"
   test -d "$restore_guard" && \
     test ! -e "$failed_restore" && \
     docker compose stop backups minecraft && \
     mv minecraft "$failed_restore" && \
     chmod 700 "$failed_restore" && \
     mv "$restore_guard" minecraft && \
     docker compose up -d --no-deps --force-recreate --wait minecraft
   ```

   `minecraft` が存在しない状態で Minecraft を起動すると、Docker が空のディレクトリを作成し、新しいワールドが生成されます。
   退避先を確認してから入れ替えるため、`restore_guard` を置き換えていない場合は最初の `test` で停止します。

   `$failed_restore` には失敗した復元結果が残ります。
   原因の調査が終わるまで削除しないでください。

3. 退避前のデータに戻ったことを確認する

   ```sh
   docker compose logs --tail=160 minecraft
   ```

   復元前のワールドと権限設定で Minecraft が起動していることを確認してから次へ進んでください。

4. バックアップと CoreProtect の定期処理を再開する

   ```sh
   docker compose up -d --no-deps --wait minecraft && \
     ./scripts/coreprotect-backup-db.sh && \
     sleep 1 && \
     docker compose run --rm --no-deps backups now && \
     ./scripts/verify-backups.sh && \
     docker compose up -d --no-deps --wait backups && \
     sudo systemctl start mc-coreprotect-db-backup.timer mc-coreprotect-purge.timer && \
     systemctl is-active mc-coreprotect-db-backup.timer && \
     systemctl is-active mc-coreprotect-purge.timer && \
     sudo rm -f .coreprotect-maintenance
   ```

   手順2で backups を停止しているため、ワールドの取得は[常駐する backups が動いていない場合](#常駐する-backups-が動いていない場合)の形式になっています。
   `verify-backups.sh` が失敗すると後続のコマンドは実行されず、常駐する `backups` と CoreProtect の timer も再開しません。
   timer の再開に失敗した場合は `.coreprotect-maintenance` が残ります。
   エラーを解決するまで playit を起動しないでください。
   表示されたエラーを解決してから手順4を再実行してください。

ここまでで退避前の状態に戻ります。
外部接続と参加の再開は、[サーバーを公開へ戻す](#サーバーを公開へ戻す)の手順で行ってください。

## プロジェクトディレクトリだけを失った場合

`BACKUP_ROOT` が残っていても、削除したプロジェクトの CoreProtect systemd timer と既存コンテナが動き続けている可能性があります。
最初に定期処理とコンテナを停止してください。

```sh
sudo systemctl disable --now \
  mc-coreprotect-db-backup.timer \
  mc-coreprotect-purge.timer
sudo systemctl stop \
  mc-coreprotect-db-backup.service \
  mc-coreprotect-purge.service
for container in playit minecraft-backups minecraft; do
  docker container inspect "$container" >/dev/null 2>&1 && docker container stop "$container"
done
```

`systemctl list-timers 'mc-coreprotect-*'` と `docker ps -a` で、旧環境の定期処理とコンテナが残っていないことを確認してください。

次に、本番と同じコミットを新しいプロジェクトディレクトリへ配置してください。
`.env`, `.discordsrv.env`, `config/server-icon.png` は、バックアップアーカイブではなく、事前に決めた安全な管理元から復元してください。
`.env` の `BACKUP_ROOT` には生存した保存先を設定する必要があります。

新しい空の保存先を作らず、生存したバックアップを参照できることを確認してください。

```sh
backup_root="$(./scripts/backup-root.sh)"
find "$backup_root/world" -maxdepth 1 -type f -name 'minecraft-*.tar.gz'
find "$backup_root/coreprotect" -maxdepth 1 -type f -name 'coreprotect-*.db.gz'
./scripts/verify-backups.sh
```

ワールドまたは CoreProtect のどちらか一方でもアーカイブが見つからない場合は、`BACKUP_ROOT` の値を見直してから再確認してください。

検査後は、[最新バックアップから復元する](#最新バックアップから復元する)の手順6から手順12までを実行してください。
この経路では最初に timer を無効化しており、残っている unit も削除したプロジェクトのパスを指すため、手順13の timer 操作は実行しないでください。

手順12まで完了したら、Maintenance モードを有効にしてバックアップを作成してください。

```sh
docker compose exec minecraft rcon-cli maintenance on && \
  docker compose up -d --no-deps --wait minecraft && \
  ./scripts/coreprotect-backup-db.sh && \
  sleep 1 && \
  docker compose run --rm --no-deps backups now && \
  ./scripts/verify-backups.sh && \
  docker compose up -d --no-deps --wait backups
```

この経路では backups が未起動のため、ワールドの取得は[常駐する backups が動いていない場合](#常駐する-backups-が動いていない場合)の形式になっています。
生存したアーカイブが唯一の復元候補であるため、検査に失敗した状態で定期処理を再開しないでください。
復元したデータに問題がある場合は、[復元を取り消す](#復元を取り消す)を実行しないでください。
この経路の退避先は削除前のサーバーデータではなく、新しいプロジェクトディレクトリの初期状態だからです。

別のアーカイブでやり直す場合は、現在の復元結果を退避して初期状態へ戻してください。

```sh
restore_guard="<手順6で表示された退避先>"
failed_restore="minecraft.project-loss-restore.failed.$(date +%Y%m%d-%H%M%S)"
test -d "$restore_guard" && \
  test ! -e "$failed_restore" && \
  docker compose stop backups minecraft && \
  mv minecraft "$failed_restore" && \
  chmod 700 "$failed_restore" && \
  mv "$restore_guard" minecraft
```

Minecraft は起動せず、[最新バックアップから復元する](#最新バックアップから復元する)の手順6から手順12までを別のアーカイブで実行してください。

復元したデータとバックアップの検査に成功したら、新しいプロジェクトディレクトリで timer を作り直してください。

```sh
sudo ./scripts/install-systemd-timers.sh && \
  systemctl is-active mc-coreprotect-db-backup.timer && \
  systemctl is-active mc-coreprotect-purge.timer
```

2つの timer が `active` になったことを確認してから、[サーバーを公開へ戻す](#サーバーを公開へ戻す)へ進んでください。

## CoreProtect の古い記録を削除する

CoreProtect の purge は履歴を削除します。
Minecraft が正常に稼働し、CoreProtect のバックアップを検査済みであることを確認してから実行してください。

```sh
./scripts/coreprotect-backup-db.sh && \
  ./scripts/coreprotect-purge-30d.sh
```

削除対象の期間は `scripts/coreprotect-purge-30d.sh` で確認できます。

## systemd timer を設定する

本番の Ubuntu ホストでは、CoreProtect のバックアップと purge を systemd timer で実行します。
本構成の状態検査、保守停止、復元手順は、ここで作成する unit を前提とします。
インストール前に、実行ユーザーが Docker を操作でき、ホストに `sqlite3`, `flock`, `runuser` があることを確認してください。

```sh
sudo ./scripts/install-systemd-timers.sh
```

スクリプトは unit を `/etc/systemd/system` へ配置し、timer を有効にします。
実行時刻と実行コマンドは `scripts/install-systemd-timers.sh`、保持数は `scripts/coreprotect-backup-db.sh` の `KEEP_GENERATIONS` を正とします。

```sh
systemctl list-timers 'mc-coreprotect-*'
systemctl status mc-coreprotect-db-backup.timer mc-coreprotect-purge.timer
journalctl -u mc-coreprotect-db-backup.service -u mc-coreprotect-purge.service
```

JST で実行する場合は、ホストのタイムゾーンが `Asia/Tokyo` であることを確認してください。

```sh
timedatectl
```

timer の実行に失敗した場合は、journal のエラーを修正してから[CoreProtect の項目を解決する](#coreprotect-の項目を解決する)で失敗状態を解除してください。
同じ節には CoreProtect のバックアップを手動で実行して成功を確かめる手順もあります。
purge の成功をその場で確かめる場合は、[CoreProtect の古い記録を削除する](#coreprotect-の古い記録を削除する)のコマンドを使います。
purge は Minecraft の RCON を待って再試行し、それでも失敗した場合は systemd が5分後に再実行します。

timer を使用しない構成へ戻す場合は、生成された unit だけを無効化して削除してください。

```sh
sudo ./scripts/uninstall-systemd-timers.sh
```

## サーバーを更新する

Paper、プラグイン、Docker イメージの更新手順は [jar と Docker イメージの検証](security.md) を参照してください。
更新前に[更新前の準備](security.md#更新前の準備)で playit を停止してから Maintenance モードを有効にし、ワールドと CoreProtect をバックアップする必要があります。

更新後は[サーバーを公開へ戻す](#サーバーを公開へ戻す)で参加制限と必須プラグインを確認してから playit を起動してください。
検証に失敗した場合は playit を停止したまま、[更新を取り消す](security.md#更新を取り消す)で更新前の内容へ戻してください。

## 自動休止と夜のスキップ

プレイヤーがいない状態が続くと、`compose.yml` の `PAUSE_WHEN_EMPTY_SECONDS` に従ってワールドの進行を休止します。
プレイヤーが接続すると自動で再開します。

無操作のプレイヤーを切断するまでの時間は、`compose.yml` の `PLAYER_IDLE_TIMEOUT` で管理しています。
オンラインのプレイヤーが寝たときの夜スキップ条件は、`compose.yml` の `RCON_CMDS_STARTUP` が起動時に実行する `gamerule players_sleeping_percentage` で設定します。
