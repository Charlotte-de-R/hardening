#!/bin/bash
# check_update.sh
# Usage: ./check_update.sh <target_image> <package_manager>

IMAGE=$1
PKG_MGR=$2

echo "🔍 Checking updates for existing image: $IMAGE ($PKG_MGR)..."

# 1. 自分のイメージをPullしてみる
if ! docker pull "$IMAGE" >/dev/null 2>&1; then
  echo "✨ Image not found (First run?). Build required."
  echo "needs_update=true" >> $GITHUB_OUTPUT
  exit 0
fi

UPDATES=""

# 2. パッケージ更新チェック
if [ "$PKG_MGR" == "apk" ]; then
  # Alpine
  UPDATES=$(docker run --rm --entrypoint sh "$IMAGE" -c "apk update >/dev/null 2>&1 && apk list -u 2>/dev/null")
elif [ "$PKG_MGR" == "apt" ]; then
  # Debian/Ubuntu
  UPDATES=$(docker run --rm --entrypoint sh "$IMAGE" -c "apt-get update >/dev/null 2>&1 && apt-get -s upgrade 2>/dev/null | grep '^Inst'")
fi

# 3. 判定
if [ -n "$UPDATES" ]; then
  echo "✨ Updates found in hardened image. Re-build required."
  echo "needs_update=true" >> $GITHUB_OUTPUT
else
  echo "💤 Hardened image is up-to-date. Skipping build."
  echo "needs_update=false" >> $GITHUB_OUTPUT
fi
