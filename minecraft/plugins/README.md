# プラグイン管理

このディレクトリは、Minecraft サーバーが読み込むプラグインの jar と、プラグインが生成する設定やデータの保存先です。
Minecraft コンテナは起動時に、`config/modrinth-projects.txt` の指定に従って Modrinth から jar を取得します。
このファイルは `compose.yml` の `MODRINTH_PROJECTS` が指しており、`config/` をコンテナの `/extras` へマウントして渡しています。
Modrinth から取得しないのは DiscordGuildGate だけで、`scripts/build-discord-guild-gate.sh` がリポジトリ内のソースコードから `DiscordGuildGate.jar` を生成します。

jar をこのディレクトリへ手動で追加しないでください。
`scripts/verify-jars.sh` は、このディレクトリ直下の jar のファイル名が `config/modrinth-lock.tsv` にちょうど1件登録されていることを確認し、登録がないか重複している jar を `untracked or duplicate plugin jar` として失敗させます。
`DiscordGuildGate.jar` はこの検査の対象外で、`config/discord-guild-gate-lock.tsv` の SHA-256 と照合します。
取得するプラグインを追加または変更する場合は、`config/modrinth-projects.txt` の行を `<slug>:<version>` の形式で追加または変更し、[Modrinth のプラグインを更新する](../../docs/security.md#modrinth-のプラグインを更新する)の手順でロックファイルを更新してください。

`DiscordSRV/`, `DiscordGuildGate/`, `TabTPS/` の設定のうちリポジトリで管理している項目は、`scripts/configure-runtime-settings.sh` を実行すると上書きされます。
これらを変更する場合は、[管理対象の設定を反映する](../../docs/configuration.md#管理対象の設定を反映する)の手順に従ってください。
