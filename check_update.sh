#!/bin/bash
# Usage: ./check_update.sh <target_image>

IMAGE=$1
IMAGE_NAME=$(echo "$IMAGE" | awk -F'/' '{print $NF}' | cut -d':' -f1)

echo "🔍 Checking updates for: $IMAGE (Name: $IMAGE_NAME)..."

# 1. リモートにイメージが存在しない場合はビルド
if ! docker pull "$IMAGE" >/dev/null 2>&1; then
  echo "✨ Image does not exist remotely. Triggering build."
  echo "needs_update=true" >> $GITHUB_OUTPUT
  MISSING_IMAGE=true
else
  MISSING_IMAGE=false
fi

# イメージに焼き込まれたバージョン（LABEL）を取得
CURRENT_VER=$(docker inspect -f '{{ index .Config.Labels "org.opencontainers.image.version" }}' "$IMAGE" 2>/dev/null || echo "")

# ==========================================
# 2. GitHub API 監視設定（全アプリ対応）
# ==========================================
REPO=""
STRIP_V=false
STRIP_PREFIX=""

case "$IMAGE_NAME" in
    "tailscale")    REPO="tailscale/tailscale" ;;
    "crowdsec")     REPO="crowdsecurity/crowdsec" ;;
    "vaultwarden")  REPO="dani-garcia/vaultwarden"; STRIP_V=true ;;
    "immich-server"|"immich-machine-learning") REPO="immich-app/immich" ;;
    "nextcloud")    REPO="nextcloud/server"; STRIP_V=true ;;
    "mariadb")      REPO="MariaDB/server"; STRIP_PREFIX="mariadb-" ;;
    "socket-proxy") REPO="Tecnativa/docker-socket-proxy"; STRIP_V=true ;;
    "promtail")     REPO="grafana/loki"; STRIP_V=true ;;
    "tetragon")     REPO="cilium/tetragon" ;;
    "portainer")    REPO="portainer/portainer"; STRIP_V=true ;;
    # 💡 immich-postgres/immich-redis はベースOSの更新チェックのみに任せるため除外
esac

# ==========================================
# 3. アプリ本体のバージョンチェックと判定
# ==========================================
if [ -n "$REPO" ]; then
    echo "🌐 Fetching latest release for $REPO..."
    
    # Releases API で取得
    RAW_TAG=$(curl -sL "https://api.github.com/repos/${REPO}/releases/latest" | jq -r .tag_name 2>/dev/null)
    
    # Release機能を使っていないリポジトリの場合は Tags API を使用
    if [ "$RAW_TAG" == "null" ] || [ -z "$RAW_TAG" ]; then
        RAW_TAG=$(curl -sL "https://api.github.com/repos/${REPO}/tags" | jq -r '.[0].name' 2>/dev/null)
    fi
    
    if [ "$RAW_TAG" != "null" ] && [ -n "$RAW_TAG" ]; then
        LATEST_VER="$RAW_TAG"
        
        # Docker Hub 等のタグ規則に合わせて表記揺れを吸収
        if [ "$STRIP_V" = true ]; then LATEST_VER="${LATEST_VER#v}"; fi
        if [ -n "$STRIP_PREFIX" ]; then LATEST_VER="${LATEST_VER#$STRIP_PREFIX}"; fi
        
        # ★取得したバージョンをワークフロー側に渡す
        echo "latest_version=$LATEST_VER" >> $GITHUB_OUTPUT
        
        if [ "$MISSING_IMAGE" = true ]; then exit 0; fi

        if [ "$CURRENT_VER" != "$LATEST_VER" ]; then
            echo "✨ Upstream update detected! (Current: ${CURRENT_VER:-None} -> Latest: $LATEST_VER)"
            echo "needs_update=true" >> $GITHUB_OUTPUT
            exit 0
        else
            echo "✅ Upstream app is up-to-date (Version: $CURRENT_VER)."
        fi
    else
        echo "⚠️ Could not fetch release from $REPO"
        if [ "$MISSING_IMAGE" = true ]; then exit 0; fi
    fi
else
    echo "ℹ️ $IMAGE_NAME is not monitored via API. Falling back to OS package check."
    if [ "$MISSING_IMAGE" = true ]; then exit 0; fi
fi

# ==========================================
# 4. OSパッケージの更新チェック (維持)
# ==========================================
CHECK_CMD='
if [ -f /etc/alpine-release ]; then
    apk update >/dev/null 2>&1 && apk list -u 2>/dev/null
elif command -v apt-get >/dev/null; then
    apt-get update >/dev/null 2>&1 && apt-get -s upgrade 2>/dev/null | grep -E "^Inst|^Conf"
else
    echo ""
fi
'

OUTPUT=$(docker run --rm --user 0:0 --entrypoint sh "$IMAGE" -c "$CHECK_CMD" 2>&1 || true)

if echo "$OUTPUT" | grep -q "executable file not found"; then
    echo "💤 Image has no shell (scratch/distroless). Skipping OS package check."
    echo "needs_update=false" >> $GITHUB_OUTPUT
    exit 0
fi

UPDATES=$(echo "$OUTPUT" | grep -v "fetch http" | grep -v "WARNING" | grep -E "[a-zA-Z0-9]")

if [ -n "$UPDATES" ]; then
  echo "✨ OS Updates detected!"
  echo "$UPDATES"
  echo "needs_update=true" >> $GITHUB_OUTPUT
else
  echo "💤 Image OS is up-to-date."
  echo "needs_update=false" >> $GITHUB_OUTPUT
fi
