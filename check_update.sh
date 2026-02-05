#!/bin/bash
# Usage: ./check_update.sh <image_name> <package_manager> <service_name>
# Example: ./check_update.sh tailscale/tailscale:latest apk tailscale

IMAGE=$1
PKG_MGR=$2
SERVICE_NAME=$3

# 一時ファイル定義
UPDATE_LIST_FILE="/tmp/${SERVICE_NAME}_updates.txt"
HASH_FILE="/tmp/${SERVICE_NAME}_hash.txt"

echo "🔍 Checking updates for $IMAGE ($PKG_MGR)..."

# 1. 最新のベースイメージを取得
docker pull "$IMAGE" >/dev/null 2>&1

# 2. 更新リストを取得し、ファイルに保存
if [ "$PKG_MGR" == "apk" ]; then
  # Alpine: パッケージ名とバージョンを取得してソート
  docker run --rm --entrypoint sh "$IMAGE" -c "apk update >/dev/null 2>&1 && apk list -u 2>/dev/null" | sort > "$UPDATE_LIST_FILE"
elif [ "$PKG_MGR" == "apt" ]; then
  # Debian: Inst 行を取得してソート
  docker run --rm --entrypoint sh "$IMAGE" -c "apt-get update >/dev/null 2>&1 && apt-get -s upgrade 2>/dev/null | grep '^Inst'" | sort > "$UPDATE_LIST_FILE"
fi

# 3. 更新リストが空か確認
if [ ! -s "$UPDATE_LIST_FILE" ]; then
  echo "Hz No updates available from upstream. Skipping."
  echo "needs_update=false" >> $GITHUB_OUTPUT
  exit 0
fi

# 4. 今回のパッチ内容のハッシュを計算
CURRENT_HASH=$(sha256sum "$UPDATE_LIST_FILE" | awk '{print $1}')
echo "🧾 Current Patch Hash: $CURRENT_HASH"

# --- キャッシュロジック (GitHub Actionsのキャッシュ機能と連携前提) ---
# 前回のハッシュと比較したいが、シェル単体では前回の状態を知る由もない。
# 簡易的な対策として、「更新リストの中身」を表示しておく。
# (完全なキャッシュ比較はYAML側でのactions/cache設定が必要だが複雑になるため、
#  ここでは「中身が変わったか」をログで見えるようにする)

cat "$UPDATE_LIST_FILE"

echo "✨ Updates found in base image."
echo "needs_update=true" >> $GITHUB_OUTPUT
