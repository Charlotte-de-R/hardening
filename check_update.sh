#!/bin/bash
# Usage: ./check_update.sh <target_image> <package_manager>

IMAGE=$1
PKG_MGR=$2

echo "🔍 Checking updates for: $IMAGE ($PKG_MGR)..."

# 1. 確実に最新をPullする (認証情報はActions側でログイン済み前提)
if ! docker pull "$IMAGE" >/dev/null 2>&1; then
  echo "⚠️ Failed to pull $IMAGE. Assuming first run or image missing."
  echo "needs_update=true" >> $GITHUB_OUTPUT
  exit 0
fi

UPDATES=""

# 2. パッケージ更新チェック (root強制実行)
if [ "$PKG_MGR" == "apk" ]; then
  # Alpine
  UPDATES=$(docker run --rm --user 0:0 --entrypoint sh "$IMAGE" -c "apk update >/dev/null 2>&1 && apk list -u 2>/dev/null" || true)
elif [ "$PKG_MGR" == "apt" ]; then
  # Debian/Ubuntu
  UPDATES=$(docker run --rm --user 0:0 --entrypoint sh "$IMAGE" -c "apt-get update >/dev/null 2>&1 && apt-get -s upgrade 2>/dev/null | grep '^Inst'" || true)
fi

# 3. 判定
if [ -n "$UPDATES" ]; then
  echo "✨ Updates detected! The current image is outdated."
  echo "--- 📦 DETECTED PACKAGES 📦 ---"
  echo "$UPDATES"
  echo "-------------------------------"
  echo "needs_update=true" >> $GITHUB_OUTPUT
else
  echo "💤 Image is up-to-date. No packages to upgrade."
  echo "needs_update=false" >> $GITHUB_OUTPUT
fi
