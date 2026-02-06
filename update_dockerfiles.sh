#!/bin/bash
# update_dockerfiles.sh

# 定義ファイルの読み込み
DEBIAN_SNIPPET=$(cat templates/debian_hardening.txt)
ALPINE_SNIPPET=$(cat templates/alpine_hardening.txt)

# ----------------------------------------
# 1. Debian系イメージのリスト
# ----------------------------------------
DEBIAN_TARGETS=(
    "dockerfiles/nextcloud/Dockerfile.hardened"
    "dockerfiles/immich-server/Dockerfile.hardened"
    "dockerfiles/immich-machine-learning/Dockerfile.hardened"
    "dockerfiles/immich-postgres/Dockerfile.hardened"
    "dockerfiles/mariadb/Dockerfile.hardened"
    "dockerfiles/vaultwarden/Dockerfile.hardened"
)

# ----------------------------------------
# 2. Alpine系イメージのリスト
# ----------------------------------------
ALPINE_TARGETS=(
    "dockerfiles/crowdsec/Dockerfile.hardened"
    "dockerfiles/immich-redis/Dockerfile.hardened"
    "dockerfiles/socket-proxy/Dockerfile.hardened"
    "dockerfiles/tailscale/Dockerfile.hardened"
)

echo "🔄 Dockerfileの一括更新を開始します..."

# 関数: ファイル内の目印をスニペットで置換する
update_file() {
    local target_file=$1
    local snippet_content=$2
    local temp_file="${target_file}.tmp"

    if [ ! -f "$target_file" ]; then
        echo "⚠️  File not found: $target_file (Skipping)"
        return
    fi

    # 既存のマーカー区間があれば削除し、新しい目印に戻す（再実行対応）
    # ※シンプルにするため、一度目印行を探して、その行をスニペットで置換する方式をとります
    
    # 1. マーカーで置換 (sedを使用)
    # 改行を含む置換はsedだと複雑になるため、awkまたはpythonが安全ですが、
    # ここでは perl を使って確実に置換します。
    
    export CONTENT="$snippet_content"
    perl -i -0777 -pe 's/# --- COMMON HARDENING START.*?# --- COMMON HARDENING END ---/# INSERT_HARDENING_HERE/gs' "$target_file"
    perl -i -0777 -pe 's/# INSERT_HARDENING_HERE/$ENV{CONTENT}/ge' "$target_file"

    echo "✅ Updated: $target_file"
}

# Debian系ループ
for file in "${DEBIAN_TARGETS[@]}"; do
    update_file "$file" "$DEBIAN_SNIPPET"
done

# Alpine系ループ
for file in "${ALPINE_TARGETS[@]}"; do
    update_file "$file" "$ALPINE_SNIPPET"
done

echo "🎉 全てのDockerfileが最新の定義に更新されました！"
