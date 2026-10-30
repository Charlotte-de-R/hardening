#!/bin/bash
# update_dockerfiles.sh

UNIVERSAL_SNIPPET=$(cat templates/universal_hardening.txt)

ALL_TARGETS=(
    # Nextcloud excludes universal_hardening as sid upgrade breaks Apache (exit 137)
    # "dockerfiles/nextcloud/Dockerfile.hardened"
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
    "dockerfiles/tetragon/Dockerfile.hardened"
    "dockerfiles/cryptpad/Dockerfile.hardened"
    "dockerfiles/portainer/Dockerfile.hardened"
)

echo "🔄 Injecting UNIVERSAL hardening templates..."

update_file() {
    local target_file=$1
    local snippet_content=$2

    if [ ! -f "$target_file" ]; then
        echo "⚠️  File not found: $target_file (Skipping)"
        return
    fi

    export CONTENT="$snippet_content"
    perl -i -0777 -pe '
        BEGIN { $content = $ENV{CONTENT}; }
        s/# --- COMMON HARDENING START.*?# --- COMMON HARDENING END ---/# INSERT_HARDENING_HERE/gs;
        my $search = "# INSERT_HARDENING_HERE";
        my $pos = index($_, $search);
        while ($pos != -1) {
            substr($_, $pos, length($search), $content);
            $pos = index($_, $search, $pos + length($content));
        }
    ' "$target_file"

    echo "✅ Updated: $target_file"
}

if [ -n "${1:-}" ]; then
    if [[ "$1" =~ ^- ]]; then
        echo "Error: Invalid target '$1'. Target cannot start with a hyphen."
        exit 1
    fi

    TARGET="$1"
    if [ -d "$TARGET" ]; then
        TARGET="${TARGET%/}/Dockerfile.hardened"
    fi

    if [[ "$TARGET" == *"nextcloud/Dockerfile.hardened"* ]]; then
        echo "⚠️ Skipping Nextcloud as it is excluded from universal hardening."
        TARGETS=()
    else
        TARGETS=("$TARGET")
    fi

else
    TARGETS=("${ALL_TARGETS[@]}")
fi

for file in "${TARGETS[@]}"; do update_file "$file" "$UNIVERSAL_SNIPPET"; done
