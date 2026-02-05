#!/bin/bash
# check_update.sh (Debug Enhanced)
IMAGE=$1
PKG_MGR=$2

echo "🔍 Checking updates for existing image: $IMAGE ($PKG_MGR)..."

# 1. 自分のイメージをPull (なければ初回とみなす)
if ! docker pull "$IMAGE" >/dev/null 2>&1; then
  echo "✨ Image not found (First run?). Build required."
  echo "needs_update=true" >> $GITHUB_OUTPUT
  exit 0
fi

UPDATES=""

# 2. パッケージ更新チェック (root強制実行)
#    エラーが出ても止まらないよう || true をつける
if [ "$PKG_MGR" == "apk" ]; then
  # Alpine
  UPDATES=$(docker run --rm --user 0:0 --entrypoint sh "$IMAGE" -c "apk update >/dev/null 2>&1 && apk list -u 2>/dev/null" || true)
elif [ "$PKG_MGR" == "apt" ]; then
  # Debian/Ubuntu
  # apt-get upgrade でシミュレーション
  UPDATES=$(docker run --rm --user 0:0 --entrypoint sh "$IMAGE" -c "apt-get update >/dev/null 2>&1 && apt-get -s upgrade 2>/dev/null | grep '^Inst'" || true)
fi

# 3. 判定とデバッグ出力
if [ -n "$UPDATES" ]; then
  echo "✨ Updates found in hardened image. Re-build required."
  echo "--- 📦 DETECTED PACKAGES 📦 ---"
  echo "$UPDATES"
  echo "-------------------------------"
  echo "needs_update=true" >> $GITHUB_OUTPUT
else
  echo "💤 Hardened image is up-to-date. Skipping build."
  echo "needs_update=false" >> $GITHUB_OUTPUT
fi
