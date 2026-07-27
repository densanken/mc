#!/usr/bin/env bash
set -euo pipefail

# Minecraft が取得した Paper と DiscordSRV の jar を classpath にして DiscordGuildGate を build する
# compile は host の JDK ではなく Docker の JDK image で実行する
# 出力先は Git 非追跡の minecraft/plugins/DiscordGuildGate.jar

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
output_jar="$root_dir/minecraft/plugins/DiscordGuildGate.jar"
builder_image="images.flatt.tech/takumi/jdk@sha256:5f9a000e89cad11d1f5a4a94bed58bbb1267372a73b9b4fa1bfbc3f14fa05aad"
source_file="$root_dir/custom-plugins/DiscordGuildGate/src/main/java/io/github/densanken/mc/discordguildgate/DiscordGuildGate.java"
test_file="$root_dir/custom-plugins/DiscordGuildGate/src/test/java/io/github/densanken/mc/discordguildgate/DiscordGuildGateTest.java"
resources_dir="$root_dir/custom-plugins/DiscordGuildGate/src/main/resources"
libraries_dir="$root_dir/minecraft/libraries"
paper_api_jars=()
while IFS= read -r jar; do
  paper_api_jars+=("$jar")
done < <(
  find "$root_dir/minecraft/libraries/io/papermc/paper/paper-api" \
    -type f -name 'paper-api-*.jar' -print 2>/dev/null
)
discordsrv_jars=()
while IFS= read -r jar; do
  discordsrv_jars+=("$jar")
done < <(
  find "$root_dir/minecraft/plugins" -maxdepth 1 -type f -name 'DiscordSRV-*.jar' -print
)

if [ "${#paper_api_jars[@]}" -ne 1 ] || [ "${#discordsrv_jars[@]}" -ne 1 ]; then
  echo "ERROR: Paper API と DiscordSRV の jar はそれぞれ1つだけ必要です。先に Minecraft を起動し、重複 jar がないことを確認してください" >&2
  exit 1
fi
discordsrv_jar="${discordsrv_jars[0]}"

build_dir="$(mktemp -d)"
output_temporary="${output_jar}.tmp.$$"
cleanup() {
  rm -rf "$build_dir"
  rm -f "$output_temporary"
}
trap cleanup EXIT HUP INT TERM

# Paper API は同梱 library に依存するため、Minecraft が取得した library 全体を classpath に含める
# 出力 jar に依存 library は同梱しない
library_classpath="$(find "$root_dir/minecraft/libraries" -type f -name '*.jar' -exec printf '%s:' {} \;)"
if [ -z "$library_classpath" ]; then
  echo "ERROR: Minecraft の library が見つかりません。先に Minecraft を一度起動してください" >&2
  exit 1
fi
library_classpath="${library_classpath%:}"
# mount path は `/` を含むため、区切り文字を変えた sed で変換する
container_library_classpath="$(printf '%s' "$library_classpath" | sed "s|$libraries_dir|/libraries|g")"

docker run --rm \
  --network none \
  --user "$(id -u):$(id -g)" \
  -v "$libraries_dir:/libraries:ro" \
  -v "$discordsrv_jar:/inputs/DiscordSRV.jar:ro" \
  -v "$source_file:/src/DiscordGuildGate.java:ro" \
  -v "$build_dir:/build" \
  --entrypoint javac \
  "$builder_image" \
  --release 25 \
  -proc:none \
  -Xlint:all,-classfile \
  -Werror \
  -cp "$container_library_classpath:/inputs/DiscordSRV.jar" \
  -d /build/classes \
  /src/DiscordGuildGate.java

docker run --rm \
  --network none \
  --user "$(id -u):$(id -g)" \
  -v "$libraries_dir:/libraries:ro" \
  -v "$discordsrv_jar:/inputs/DiscordSRV.jar:ro" \
  -v "$test_file:/test/DiscordGuildGateTest.java:ro" \
  -v "$build_dir:/build" \
  --entrypoint javac \
  "$builder_image" \
  --release 25 \
  -proc:none \
  -Xlint:all,-classfile \
  -Werror \
  -cp "$container_library_classpath:/inputs/DiscordSRV.jar:/build/classes" \
  -d /build/test-classes \
  /test/DiscordGuildGateTest.java

docker run --rm \
  --network none \
  --user "$(id -u):$(id -g)" \
  -v "$libraries_dir:/libraries:ro" \
  -v "$discordsrv_jar:/inputs/DiscordSRV.jar:ro" \
  -v "$build_dir:/build" \
  --entrypoint java \
  "$builder_image" \
  -cp "$container_library_classpath:/inputs/DiscordSRV.jar:/build/classes:/build/test-classes" \
  io.github.densanken.mc.discordguildgate.DiscordGuildGateTest

mkdir -p "$(dirname "$output_jar")"
docker run --rm \
  --network none \
  --user "$(id -u):$(id -g)" \
  -v "$resources_dir:/resources:ro" \
  -v "$build_dir:/build" \
  --entrypoint jar \
  "$builder_image" \
  --create --file /build/DiscordGuildGate.jar --date=2000-01-01T00:00:00Z \
  -C /build/classes . \
  -C /resources .

install -m 0644 "$build_dir/DiscordGuildGate.jar" "$output_temporary"
mv "$output_temporary" "$output_jar"

echo "OK: $output_jar を build しました"
