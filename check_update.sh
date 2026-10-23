
#!/bin/bash
# Usage: ./check_update.sh <target_image>

set -o pipefail

if [ -z "${1:-}" ]; then
  echo "Usage: $0 <target_image>"
  exit 1
fi

if [[ "$1" =~ ^- ]]; then
  echo "Error: Invalid image name '$1'. Image name cannot start with a hyphen."
  exit 1
fi

IMAGE="$1"
IMAGE_NAME="${IMAGE##*/}"
IMAGE_NAME="${IMAGE_NAME%%:*}"

# GitHub Actions の出力を安全に扱う
write_output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  else
    printf '%s=%s\n' "$1" "$2"
  fi
}

# バージョン比較。GNU sort -V を使用する。
version_lt() {
  local a="${1#v}"
  local b="${2#v}"

  [ -n "$a" ] && [ -n "$b" ] || return 1
  [ "$a" != "$b" ] || return 1

  [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n 1)" = "$a" ]
}

version_gt() {
  version_lt "$2" "$1"
}

echo "🔍 Checking updates for: $IMAGE (Name: $IMAGE_NAME)..."

# ==========================================
# 1. 現在の公開イメージを確認
# ==========================================
if docker pull -- "$IMAGE" >/dev/null 2>&1; then
  MISSING_IMAGE=false
else
  echo "⚠️ Could not pull the published image. A build may be required."
  MISSING_IMAGE=true
  write_output "needs_update" "true"
fi

CURRENT_VER=""
if [ "$MISSING_IMAGE" = false ]; then
  CURRENT_VER=$(
    docker inspect \
      -f '{{ index .Config.Labels "org.opencontainers.image.version" }}' \
      -- "$IMAGE" 2>/dev/null || true
  )

  # Docker の Go template が返す未設定値を空文字列に正規化
  if [ "$CURRENT_VER" = "<no value>" ] || [ "$CURRENT_VER" = "null" ]; then
    CURRENT_VER=""
  fi
fi

echo "Current image version: ${CURRENT_VER:-unknown}"

# ==========================================
# 2. 上流リポジトリの設定
# ==========================================
REPO=""
STRIP_V=false
STRIP_PREFIX=""

case "$IMAGE_NAME" in
  "tailscale")
    REPO="tailscale/tailscale"
    ;;
  "crowdsec")
    REPO="crowdsecurity/crowdsec"
    ;;
  "vaultwarden")
    REPO="dani-garcia/vaultwarden"
    STRIP_V=true
    ;;
  "immich-server"|"immich-machine-learning")
    REPO="immich-app/immich"
    ;;
  "tetragon")
    REPO="cilium/tetragon"
    ;;
  "portainer")
    REPO="portainer/portainer"
    STRIP_V=true
    ;;
  "cryptpad")
    REPO="cryptpad/cryptpad"
    ;;
  "nextcloud")
    REPO="nextcloud/server"
    STRIP_V=true
    ;;
esac

# ==========================================
# 3. 上流バージョンを取得し、ダウングレードを防ぐ
# ==========================================
LATEST_VER=""
DESIRED_VER=""

if [ -n "$REPO" ]; then
  echo "🌐 Fetching latest release for $REPO..."

  CURL_OPTS=("-fsSL" "--retry" "2" "--connect-timeout" "10")
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    CURL_OPTS+=("-H" "Authorization: Bearer $GITHUB_TOKEN")
  fi

  RAW_TAG=$(
    curl "${CURL_OPTS[@]}" \
      "https://api.github.com/repos/${REPO}/releases/latest" |
      jq -r '.tag_name // empty' 2>/dev/null || true
  )

  if [ -z "$RAW_TAG" ]; then
    RAW_TAG=$(
      curl "${CURL_OPTS[@]}" \
        "https://api.github.com/repos/${REPO}/tags?per_page=1" |
        jq -r '.[0].name // empty' 2>/dev/null || true
    )
  fi

  if [ -n "$RAW_TAG" ] && [ "$RAW_TAG" != "null" ]; then
    LATEST_VER="$RAW_TAG"

    if [ "$STRIP_V" = true ]; then
      LATEST_VER="${LATEST_VER#v}"
    fi

    if [ -n "$STRIP_PREFIX" ]; then
      LATEST_VER="${LATEST_VER#$STRIP_PREFIX}"
    fi
  else
    echo "⚠️ Could not fetch a release/tag from $REPO."
  fi

  # Nextcloud の最低許容 Docker タグ。
  # workflow から指定でき、未指定時は 34.0.4 を使用する。
  if [ "$IMAGE_NAME" = "nextcloud" ]; then
    NEXTCLOUD_MIN_VERSION="${NEXTCLOUD_MIN_VERSION:-34.0.4}"
    NEXTCLOUD_MIN_VERSION="${NEXTCLOUD_MIN_VERSION#v}"

    if [ -z "$NEXTCLOUD_MIN_VERSION" ]; then
      echo "❌ NEXTCLOUD_MIN_VERSION is empty; refusing to build."
      exit 1
    fi

    DESIRED_VER="$NEXTCLOUD_MIN_VERSION"

    # GitHub Releases API が古いバージョンを返しても、
    # 設定した最低バージョンを下回らせない。
    if [ -n "$LATEST_VER" ] &&
       version_gt "$LATEST_VER" "$DESIRED_VER"; then
      DESIRED_VER="$LATEST_VER"
    fi

    echo "Nextcloud minimum allowed version: $NEXTCLOUD_MIN_VERSION"
    echo "Nextcloud upstream release reported: ${LATEST_VER:-unavailable}"
    echo "Nextcloud selected version: $DESIRED_VER"

  elif [ -n "$LATEST_VER" ]; then
    DESIRED_VER="$LATEST_VER"
  elif [ -n "$CURRENT_VER" ] && [ "$CURRENT_VER" != "latest" ]; then
    # API 障害時に、OS 更新だけでアプリのバージョンを変えない。
    DESIRED_VER="$CURRENT_VER"
    echo "ℹ️ Falling back to current image version: $DESIRED_VER"
  fi

  # 公開済みイメージのバージョンより古い候補は拒否する。
  if [ -n "$CURRENT_VER" ] &&
     [ "$CURRENT_VER" != "latest" ] &&
     [ -n "$DESIRED_VER" ] &&
     version_lt "$DESIRED_VER" "$CURRENT_VER"; then
    echo "🛑 Downgrade rejected: candidate $DESIRED_VER is older than current $CURRENT_VER."
    DESIRED_VER="$CURRENT_VER"
  fi

  if [ -n "$DESIRED_VER" ]; then
    write_output "latest_version" "$DESIRED_VER"
  fi

  # Tailscale は既存設計どおり、Go module からソースビルドする。
  if [ "$IMAGE_NAME" = "tailscale" ] &&
     [ -n "$DESIRED_VER" ] &&
     { [ "$MISSING_IMAGE" = true ] ||
       [ -z "$CURRENT_VER" ] ||
       version_gt "$DESIRED_VER" "$CURRENT_VER"; }; then
    echo "✨ Tailscale update/build required: ${CURRENT_VER:-unknown} -> $DESIRED_VER"
    write_output "needs_update" "true"
    exit 0
  fi

  # アプリのバージョン変更またはイメージ欠落時は、
  # 上流の Docker タグが実在することを確認する。
  if [ -n "$DESIRED_VER" ] &&
     { [ "$MISSING_IMAGE" = true ] ||
       [ -z "$CURRENT_VER" ] ||
       version_gt "$DESIRED_VER" "$CURRENT_VER"; }; then

    case "$IMAGE_NAME" in
      "crowdsec")
        BASE_IMAGE_REF="ghcr.io/crowdsecurity/crowdsec:${DESIRED_VER}"
        ;;
      "nextcloud")
        BASE_IMAGE_REF="nextcloud:${DESIRED_VER}"
        ;;
      *)
        BASE_IMAGE_REF="${REPO}:${DESIRED_VER}"
        ;;
    esac

    echo "🔎 Verifying upstream image availability: $BASE_IMAGE_REF"

    if ! docker buildx imagetools inspect "$BASE_IMAGE_REF" >/dev/null 2>&1; then
      echo "❌ Upstream image not found: $BASE_IMAGE_REF"
      echo "Refusing to build with an unverified application version."
      exit 1
    fi

    echo "✨ Upstream update/build required: ${CURRENT_VER:-unknown} -> $DESIRED_VER"
    write_output "needs_update" "true"
    exit 0
  fi

  if [ -n "$DESIRED_VER" ] && [ -n "$CURRENT_VER" ]; then
    if [ "$DESIRED_VER" = "$CURRENT_VER" ]; then
      echo "✅ Application version unchanged: $CURRENT_VER"
    else
      echo "ℹ️ Keeping current version: $CURRENT_VER"
    fi
  fi

else
  echo "ℹ️ $IMAGE_NAME is not monitored via the GitHub API."

  if [ "$MISSING_IMAGE" = true ]; then
    echo "❌ Cannot verify an upstream version for missing image $IMAGE."
    echo "Refusing to build an unverified version."
    exit 1
  fi

  if [ -n "$CURRENT_VER" ] && [ "$CURRENT_VER" != "latest" ]; then
    write_output "latest_version" "$CURRENT_VER"
  fi
fi

# ==========================================
# 4. OS パッケージの更新チェック
#    アプリのバージョンは DESIRED_VER / CURRENT_VER を維持する。
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

OUTPUT=$(
  docker run --rm --user 0:0 --entrypoint sh -- "$IMAGE" \
    -c "$CHECK_CMD" 2>&1 || true
)

if echo "$OUTPUT" | grep -q "executable file not found"; then
  echo "💤 Image has no shell. Skipping OS package check."
  write_output "needs_update" "false"
  exit 0
fi

UPDATES=$(
  echo "$OUTPUT" |
    grep -v "fetch http" |
    grep -v "WARNING" |
    grep -E "[a-zA-Z0-9]" || true
)

if [ -n "$UPDATES" ]; then
  echo "✨ OS updates detected:"
  echo "$UPDATES"
  write_output "needs_update" "true"
else
  echo "💤 Image OS is up-to-date."
  # イメージが欠落している場合に必要なビルド判定は上書きしない。
  if [ "$MISSING_IMAGE" = false ]; then
    write_output "needs_update" "false"
  fi
fi
