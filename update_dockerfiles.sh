#!/bin/bash
# update_dockerfiles.sh

DEBIAN_SNIPPET=$(cat templates/debian_hardening.txt)
ALPINE_SNIPPET=$(cat templates/alpine_hardening.txt)

# Debian系ターゲット
DEBIAN_TARGETS=(
    "dockerfiles/nextcloud/Dockerfile.hardened"
    "dockerfiles/immich-server/Dockerfile.hardened"
    "dockerfiles/immich-machine-learning/Dockerfile.hardened"
    "dockerfiles/immich-postgres/Dockerfile.hardened"
    "dockerfiles/mariadb/Dockerfile.hardened"
    "dockerfiles/vaultwarden/Dockerfile.hardened"
)

# Alpine系ターゲット
ALPINE_TARGETS=(
    "dockerfiles/crowdsec/Dockerfile.hardened"
    "dockerfiles/immich-redis/Dockerfile.hardened"
    "dockerfiles/socket-proxy/Dockerfile.hardened"
    "dockerfiles/tailscale/Dockerfile.hardened"
    "dockerfiles/loki/Dockerfile.hardened"
    "dockerfiles/promtail/Dockerfile.hardened"
)

echo "🔄 Injecting hardening templates..."

update_file() {
    local target_file=$1
    local snippet_content=$2

    if [ ! -f "$target_file" ]; then
        echo "⚠️  File not found: $target_file (Skipping)"
        return
    fi

    # 既存のマーカー区間を削除して、目印だけに戻す（冪等性担保）
    perl -i -0777 -pe 's/# --- COMMON HARDENING START.*?# --- COMMON HARDENING END ---/# INSERT_HARDENING_HERE/gs' "$target_file"
    
    # 目印をスニペットで置換
    export CONTENT="$snippet_content"
    perl -i -0777 -pe 's/# INSERT_HARDENING_HERE/$ENV{CONTENT}/ge' "$target_file"

    echo "✅ Updated: $target_file"
}

for file in "${DEBIAN_TARGETS[@]}"; do update_file "$file" "$DEBIAN_SNIPPET"; done
for file in "${ALPINE_TARGETS[@]}"; do update_file "$file" "$ALPINE_SNIPPET"; done
