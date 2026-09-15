#!/bin/bash

set -e

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
"dockerfiles/tetragon/Dockerfile.hardened"
"dockerfiles/cryptpad/Dockerfile.hardened"
)

echo "🔄 Injecting UNIVERSAL hardening templates..."

update_file() {
  local target_file=$1
  local snippet_content=$2

  if [ ! -f "$target_file" ]; then
    echo "⚠️ File not found: $target_file (Skipping)"
    return
  fi

  # ベース判定（雑だが実用的）
  if grep -qiE 'debian|ubuntu' "$target_file"; then
    echo "🐧 Debian系 detected → apt hardening ON"

    HARDENING_APPEND=$(cat <<'EOF'

# --- Package minimization (Debian/Ubuntu only) ---
RUN apt-get update && \
    apt-get purge -y \
        perl \
        perl-base \
        perl-modules \
        perl-archive-tar || true && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*
EOF
)

  else
    echo "🚫 Non-Debian image → skip apt hardening"
    HARDENING_APPEND=""
  fi

  # 既存ブロック削除
  perl -i -0777 -pe 's/# --- COMMON HARDENING START.*?# --- COMMON HARDENING END ---/# INSERT_HARDENING_HERE/gs' "$target_file"

  FINAL_CONTENT="${snippet_content}
${HARDENING_APPEND}"

  export CONTENT="$FINAL_CONTENT"

  perl -i -0777 -pe 's/# INSERT_HARDENING_HERE/$ENV{CONTENT}/ge' "$target_file"

  echo "✅ Updated: $target_file"
}

for file in "${ALL_TARGETS[@]}"; do
  update_file "$file" "$UNIVERSAL_SNIPPET"
done

echo "🚀 All Dockerfiles hardened (safe mode)"
