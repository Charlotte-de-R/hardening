#!/usr/bin/env bash
# Regenerate embedded hardening snippets from the single source of truth.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

TEMPLATE="templates/universal_hardening.txt"
if [[ ! -s "$TEMPLATE" ]]; then
    echo "ERROR: hardening template is missing or empty: $TEMPLATE" >&2
    exit 1
fi
UNIVERSAL_SNIPPET="$(cat -- "$TEMPLATE")"

echo "🔄 Injecting UNIVERSAL hardening templates..."

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

update_file() {
    local target_file="$1"
    if [[ ! -f "$target_file" ]]; then
        local normalized_missing="${target_file#./}"
        if [[ "$normalized_missing" == dockerfiles/* ]]; then
            echo "ERROR: target Dockerfile not found: $target_file" >&2
            return 1
        fi
        echo "⚠️  File not found: $target_file (Skipping)"
        return 0
    fi

    local starts ends normalized
    normalized="${target_file#./}"
    starts="$(grep -Fc '# --- COMMON HARDENING START (DO NOT EDIT MANUALLY) ---' "$target_file" || true)"
    ends="$(grep -Fc '# --- COMMON HARDENING END ---' "$target_file" || true)"
    if [[ "$starts" == "0" && "$ends" == "0" ]]; then
        case "$normalized" in
            dockerfiles/nextcloud/Dockerfile.hardened|dockerfiles/immich-server/Dockerfile.hardened|dockerfiles/crowdsec/Dockerfile.hardened|dockerfiles/cryptpad/Dockerfile.hardened|dockerfiles/portainer/Dockerfile.hardened)
                echo "INFO: common template intentionally skipped for image-specific Dockerfile: $normalized"
                return 0
                ;;
            *)
                echo "ERROR: hardening markers are missing from target: $target_file" >&2
                return 1
                ;;
        esac
    fi
    if [[ "$starts" -lt 1 || "$starts" != "$ends" ]]; then
        echo "ERROR: expected matching hardening marker pairs in $target_file (start=$starts end=$ends)" >&2
        return 1
    fi

    export CONTENT="$UNIVERSAL_SNIPPET"
    perl -i -0777 -pe '
        BEGIN { $content = $ENV{CONTENT}; }
        s/# --- COMMON HARDENING START \(DO NOT EDIT MANUALLY\) ---.*?# --- COMMON HARDENING END ---/$content/sg;
    ' "$target_file"

    local new_starts new_ends
    new_starts="$(grep -Fc '# --- COMMON HARDENING START (DO NOT EDIT MANUALLY) ---' "$target_file" || true)"
    new_ends="$(grep -Fc '# --- COMMON HARDENING END ---' "$target_file" || true)"
    if [[ "$new_starts" == "$starts" && "$new_ends" == "$ends" ]]; then
        echo "✅ Updated: $target_file"
    else
        echo "ERROR: hardening marker validation failed after update: $target_file" >&2
        return 1
    fi
}

if [[ -n "${1:-}" ]]; then
    TARGET="$1"
    if [[ "$TARGET" == -* ]]; then
        echo "Error: Invalid target '$TARGET'. Target cannot start with a hyphen." >&2
        exit 1
    fi
    if [[ -d "$TARGET" ]]; then
        TARGET="${TARGET%/}/Dockerfile.hardened"
    fi
    TARGETS=("$TARGET")
else
    TARGETS=("${ALL_TARGETS[@]}")
fi

for file in "${TARGETS[@]}"; do
    update_file "$file"
done
