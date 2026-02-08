#!/bin/bash
# update_dockerfiles.sh

UNIVERSAL_SNIPPET=$(cat templates/universal_hardening.txt)

ALL_TARGETS=(
    "dockerfiles/nextcloud/Dockerfile.hardened"
    "dockerfiles/immich-server/Dockerfile.hardened"
    "dockerfiles/immich-machine-learning/Dockerfile.hardened"
    "dockerfiles/immich-postgres/Dockerfile.hardened"
    "dockerfiles/mariadb/Dockerfile.hardened"
    "dockerfiles/vaultwarden/Dockerfile.hardened"
    "dockerfiles/crowdsec/Dockerfile.hardened"
    "dockerfiles/immich-redis/Dockerfile.hardened"
    "dockerfiles/socket-proxy/Dockerfile.hardened"
    "dockerfiles/tailscale/Dockerfile.hardened"
    "dockerfiles/promtail/Dockerfile.hardened"
)

echo "🔄 Injecting UNIVERSAL hardening templates..."

update_file() {
    local target_file=$1
    local snippet_content=$2

    if [ ! -f "$target_file" ]; then
        echo "⚠️  File not found: $target_file (Skipping)"
        return
    fi

    # 既存ブロックをマーカーに戻す
    perl -i -0777 -pe 's/# --- COMMON HARDENING START.*?# --- COMMON HARDENING END ---/# INSERT_HARDENING_HERE/gs' "$target_file"
    
    export CONTENT="$snippet_content"
    perl -i -0777 -pe 's/# INSERT_HARDENING_HERE/$ENV{CONTENT}/ge' "$target_file"

    echo "✅ Updated: $target_file"
}

for file in "${ALL_TARGETS[@]}"; do update_file "$file" "$UNIVERSAL_SNIPPET"; done
