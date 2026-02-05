#!/bin/bash
# check_update.sh
# Usage: ./check_update.sh <image_name> <package_manager>
# Example: ./check_update.sh tailscale/tailscale:latest apk

IMAGE=$1
PKG_MGR=$2

echo "🔍 Checking updates for $IMAGE ($PKG_MGR)..."

# 最新のベースイメージを取得
docker pull "$IMAGE" >/dev/null 2>&1

UPDATES=""

if [ "$PKG_MGR" == "apk" ]; then
  # Alpine: apk list -u で更新パッケージがあるか確認
  # 終了コードや空文字で判定
  UPDATES=$(docker run --rm --entrypoint sh "$IMAGE" -c "apk update >/dev/null 2>&1 && apk list -u 2>/dev/null")
elif [ "$PKG_MGR" == "apt" ]; then
  # Debian/Ubuntu: apt-get -s upgrade で "Inst" (Install) 行があるか確認
  UPDATES=$(docker run --rm --entrypoint sh "$IMAGE" -c "apt-get update >/dev/null 2>&1 && apt-get -s upgrade 2>/dev/null | grep '^Inst'")
fi

if [ -n "$UPDATES" ]; then
  echo "✨ Updates found! Build is required."
  # GitHub Actionsに変数を出力
  echo "needs_update=true" >> $GITHUB_OUTPUT
else
  echo "💤 No updates found. Skipping build."
  echo "needs_update=false" >> $GITHUB_OUTPUT
fi
