#!/bin/bash
# build-id.sh 的自我檢查：在暫時的 git 專案裡跑，不碰真正的 repo。
#   bash App/scripts/build-id-check.sh
set -euo pipefail
SCRIPT="$(cd "$(dirname "$0")" && pwd)/build-id.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

fail() { echo "build id check: FAIL — $1" >&2; exit 1; }

# @feature: build-version.feature
# @scenario: 不在 git 底下時，版號是 1
mkdir "$T/plain"
[ "$(bash "$SCRIPT" "$T/plain")" = "1" ] || fail "不在 git 底下時應該是 1"

mkdir "$T/repo"
git -C "$T/repo" init -q
git -C "$T/repo" config user.email "check@example.com"
git -C "$T/repo" config user.name "check"
for n in 1 2 3; do
  echo "$n" > "$T/repo/f.txt"
  git -C "$T/repo" add f.txt
  git -C "$T/repo" commit -q -m "c$n"
done

# @feature: build-version.feature
# @scenario: build 版號是 commit 數加 commit 短碼
SHORT="$(git -C "$T/repo" rev-parse --short HEAD)"
[ "$(bash "$SCRIPT" "$T/repo")" = "3-$SHORT" ] || fail "乾淨的 3 個 commit 應該是 3-$SHORT，實際是 $(bash "$SCRIPT" "$T/repo")"

# @feature: build-version.feature
# @scenario: 有未提交的改動時，版號結尾加 -dirty
echo "changed" > "$T/repo/f.txt"
[ "$(bash "$SCRIPT" "$T/repo")" = "3-$SHORT-dirty" ] || fail "有未提交的改動應該是 3-$SHORT-dirty，實際是 $(bash "$SCRIPT" "$T/repo")"

echo "build id check: ok"
