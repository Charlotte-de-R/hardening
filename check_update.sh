#!/bin/bash
# Usage: ./check_update.sh <target_image>

IMAGE=$1

echo "🔍 Checking updates for: $IMAGE (Auto-detect)..."

if ! docker pull "$IMAGE" >/dev/null 2>&1; then
  echo "needs_update=true" >> $GITHUB_OUTPUT
  exit 0
fi

CHECK_CMD='
if [ -f /etc/alpine-release ]; then
    apk update >/dev/null 2>&1 && apk list -u 2>/dev/null
elif command -v apt-get >/dev/null; then
    apt-get update >/dev/null 2>&1 && apt-get -s upgrade 2>/dev/null | grep -E "^Inst|^Conf"
else
    echo ""
fi
'

UPDATES=$(docker run --rm --user 0:0 --entrypoint sh "$IMAGE" -c "$CHECK_CMD" || true)

if [ -n "$UPDATES" ]; then
  echo "✨ Updates detected!"
  echo "$UPDATES"
  echo "needs_update=true" >> $GITHUB_OUTPUT
else
  echo "💤 Image is up-to-date."
  echo "needs_update=false" >> $GITHUB_OUTPUT
fi
