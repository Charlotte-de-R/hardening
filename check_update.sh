#!/bin/bash
# Usage: ./check_update.sh <target_image>

IMAGE=$1
IMAGE_NAME=$(echo "$IMAGE" | awk -F'/' '{print $NF}' | cut -d':' -f1)

echo "🔍 Checking updates for: $IMAGE (Name: $IMAGE_NAME)..."

# 1. リモートにイメージが存在しない場合はビルド
if ! docker pull "$IMAGE" >/dev/null 2>&1; then
  echo "✨ Image does not exist remotely. Triggering build."
  echo "needs_update=true" >> $GITHUB_OUTPUT
  exit 0
fi

# イメージに焼き込まれたバージョン（LABEL）を取得
CURRENT_VER=$(docker inspect -f '{{ index .Config.Labels "org.opencontainers.image.version" }}' "$IMAGE" 2>/dev/null || echo "")

# 2. アプリケーション本体のバージョンチェック（Portainer / Tetragon専用）
if [ "$IMAGE_NAME" == "portainer" ] || [ "$IMAGE_NAME" == "tetragon" ]; then
    if [ "$IMAGE_NAME" == "portainer" ]; then
        LATEST_VER=$(curl -sL https://api.github.com/repos/portainer/portainer/releases/latest | jq -r .tag_name)
    elif [ "$IMAGE_NAME" == "tetragon" ]; then
        LATEST_VER=$(curl -sL https://api.github.com/repos/cilium/tetragon/releases/latest | jq -r .tag_name)
    fi

    if [ -n "$LATEST_VER" ] && [ "$LATEST_VER" != "null" ]; then
        if [ "$CURRENT_VER" != "$LATEST_VER" ]; then
            echo "✨ Upstream update detected! (Current: ${CURRENT_VER:-None} -> Latest: $LATEST_VER)"
            echo "needs_update=true" >> $GITHUB_OUTPUT
            exit 0
        else
            echo "✅ Upstream app is up-to-date (Version: $CURRENT_VER)."
            # アプリが最新でもOSの脆弱性パッチがあるかもしれないので、このまま下のOSチェックに進む
        fi
    fi
fi

# 3. OSパッケージの更新チェック
CHECK_CMD='
if [ -f /etc/alpine-release ]; then
    apk update >/dev/null 2>&1 && apk list -u 2>/dev/null
elif command -v apt-get >/dev/null; then
    apt-get update >/dev/null 2>&1 && apt-get -s upgrade 2>/dev/null | grep -E "^Inst|^Conf"
else
    echo ""
fi
'

# stderrも含めてキャプチャし、shがない場合のエラーを検知
OUTPUT=$(docker run --rm --user 0:0 --entrypoint sh "$IMAGE" -c "$CHECK_CMD" 2>&1 || true)

if echo "$OUTPUT" | grep -q "executable file not found"; then
    echo "💤 Image has no shell (scratch/distroless). Skipping OS package check."
    echo "needs_update=false" >> $GITHUB_OUTPUT
    exit 0
fi

# 通常のOSパッケージ更新チェック (fetchやWARNINGの行を除外)
UPDATES=$(echo "$OUTPUT" | grep -v "fetch http" | grep -v "WARNING" | grep -E "[a-zA-Z0-9]")

if [ -n "$UPDATES" ]; then
  echo "✨ OS Updates detected!"
  echo "$UPDATES"
  echo "needs_update=true" >> $GITHUB_OUTPUT
else
  echo "💤 Image OS is up-to-date."
  echo "needs_update=false" >> $GITHUB_OUTPUT
fi
