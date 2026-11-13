#!/bin/bash
# 印出 build 版號：<commit 數>-<commit 短碼>，工作目錄有未提交的改動時結尾加 -dirty。
# 不在 git 底下（或 git 不可用）時印 1，與 bundle.sh 原本寫死的值相同。
#   App/scripts/build-id.sh [目錄]      預設是這個腳本所在的 repo
DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
if COUNT="$(git -C "$DIR" rev-list --count HEAD 2>/dev/null)" && SHORT="$(git -C "$DIR" rev-parse --short HEAD 2>/dev/null)"; then
  ID="$COUNT-$SHORT"
  if [ -n "$(git -C "$DIR" status --porcelain 2>/dev/null)" ]; then ID="$ID-dirty"; fi
  echo "$ID"
else
  echo 1
fi
