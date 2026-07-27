# 管理対象の設定

このディレクトリは、サーバーを再構築したあとも引き継ぐプラグイン設定の管理元です。
現在の管理対象は TabTPS だけで、`TabTPS/main.conf` と `TabTPS/display-configs/default.conf` を置いています。
この2ファイルは `minecraft/plugins/TabTPS/` の同じ相対パスへコピーされるため、TabTPS の設定を変更するときは、コピー先ではなくこのディレクトリのファイルを編集してください。
コピー先へ直接加えた変更は、次の反映で上書きされます。

`scripts/configure-runtime-settings.sh` は、このコピーとあわせて DiscordSRV と DiscordGuildGate の実行時設定も更新します。
プロジェクトルートで次のコマンドを実行してください。

```sh
./scripts/configure-runtime-settings.sh
```

実行するタイミング、Minecraft の再起動、公開中のサーバーで先に外部公開を停止する手順は、[管理対象の設定を反映する](../../docs/configuration.md#管理対象の設定を反映する)に従ってください。
