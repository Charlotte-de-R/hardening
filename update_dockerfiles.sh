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
        echo "ERROR: target Dockerfile not found: $target_file" >&2
        return 1
    fi

    local starts ends
    starts="$(grep -Fc '# --- COMMON HARDENING START (DO NOT EDIT MANUALLY) ---' "$target_file" || true)"
    ends="$(grep -Fc '# --- COMMON HARDENING END ---' "$target_file" || true)"
    if [[ "$starts" != "1" || "$ends" != "1" ]]; then
        echo "ERROR: expected exactly one hardening marker pair in $target_file (start=$starts end=$ends)" >&2
        return 1
    fi

    export CONTENT="$UNIVERSAL_SNIPPET"
    perl -i -0777 -pe '
        BEGIN { $content = $ENV{CONTENT}; }
        s/# --- COMMON HARDENING START \(DO NOT EDIT MANUALLY\) ---.*?# --- COMMON HARDENING END ---/$content/sg;
    ' "$target_file"

    if grep -Fq '# --- COMMON HARDENING START (DO NOT EDIT MANUALLY) ---' "$target_file" &&
       grep -Fq '# --- COMMON HARDENING END ---' "$target_file"; then
        echo "Updated: $target_file"
    else
        echo "ERROR: hardening marker validation failed after update: $target_file" >&2
        return 1
    fi
}

if [[ -n "${1:-}" ]]; then
    TARGET="$1"
    if [[ "$TARGET" == -* ]]; then
        echo "ERROR: invalid target '$TARGET'" >&2
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
