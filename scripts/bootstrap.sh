#!/bin/bash
# scripts/bootstrap.sh [--dry-run]
#
# Builds what a fresh checkout of lmux needs before App/scripts/bundle.sh works:
# App/Frameworks/GhosttyKit.xcframework is a symlink into vendor/ghostty, which is not
# part of the repo. This script, run from anywhere inside the checkout:
#   1. clones ghostty-org/ghostty into vendor/ghostty at the commit pinned in GHOSTTY_COMMIT
#      (skipped if vendor/ghostty is already a checkout of exactly that commit) and applies
#      scripts/ghostty.patch (lmux's changes to libghostty; skipped if already applied);
#   2. downloads Zig 0.17.0 (the version that commit requires) into .tools/zig, checking the
#      tarball's sha256 against the value pinned below (skipped if .tools/zig is 0.17.0);
#   3. builds libghostty as an xcframework, with exactly the flags lmux is developed with.
# Needs: git, curl, shasum, tar, and Xcode (zig build uses its SDK and Metal compiler; set
# DEVELOPER_DIR if your Xcode isn't the selected one). --dry-run prints the plan, runs nothing.
set -euo pipefail

DRY_RUN=0
case "${1:-}" in
  --dry-run) DRY_RUN=1 ;;
  "") ;;
  -h|--help) sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "error: unknown argument: $1" >&2; exit 1 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GHOSTTY_REPO="https://github.com/ghostty-org/ghostty.git"
GHOSTTY_COMMIT="$(tr -d '[:space:]' < "$ROOT/GHOSTTY_COMMIT")"
[[ "$GHOSTTY_COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo "error: GHOSTTY_COMMIT is not a full commit hash" >&2; exit 1; }
GHOSTTY_DIR="$ROOT/vendor/ghostty"

ZIG_VERSION="0.17.0"
case "$(uname -m)" in
  arm64)  ZIG_ARCH="aarch64"; ZIG_SHA256="b607e9b9234790a008116ae5bdb71c6243b84b9fb42a53a9e70fde41c06c536a" ;;
  x86_64) ZIG_ARCH="x86_64";  ZIG_SHA256="4f9a1c5269aa17ebda5e6d3c2b89d6cbf36f7d2b22a0306e9ab98f25f95529c6" ;;
  *) echo "error: unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac
ZIG_TARBALL="zig-$ZIG_ARCH-macos-$ZIG_VERSION.tar.xz"
ZIG_URL="https://ziglang.org/download/$ZIG_VERSION/$ZIG_TARBALL"
ZIG_DIR="$ROOT/.tools/zig"
ZIG_FLAGS=(-Demit-xcframework=true -Dxcframework-target=native -Demit-macos-app=false -Doptimize=ReleaseFast)

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then printf '  $'; printf ' %q' "$@"; printf '\n'; else "$@"; fi
}

echo "== lmux bootstrap$([[ $DRY_RUN -eq 1 ]] && echo ' (dry run: nothing is run)') =="
echo "checkout: $ROOT"
echo ""

echo "1. Ghostty $GHOSTTY_COMMIT -> vendor/ghostty"
if [[ -d "$GHOSTTY_DIR/.git" ]] && [[ "$(git -C "$GHOSTTY_DIR" rev-parse HEAD 2>/dev/null)" == "$GHOSTTY_COMMIT" ]]; then
  echo "  already at the pinned commit, skipped"
elif [[ -e "$GHOSTTY_DIR" ]]; then
  echo "error: $GHOSTTY_DIR exists but is not a checkout of $GHOSTTY_COMMIT; move it away first" >&2
  exit 1
else
  run mkdir -p "$GHOSTTY_DIR"
  run git -C "$GHOSTTY_DIR" init -q
  run git -C "$GHOSTTY_DIR" remote add origin "$GHOSTTY_REPO"
  run git -C "$GHOSTTY_DIR" fetch -q --depth 1 origin "$GHOSTTY_COMMIT"
  run git -C "$GHOSTTY_DIR" checkout -q --detach FETCH_HEAD
fi
# lmux's changes to libghostty, kept as one patch on top of GHOSTTY_COMMIT (see the patch's header).
PATCH="$ROOT/scripts/ghostty.patch"
if [[ "$DRY_RUN" -eq 1 ]]; then
  run git -C "$GHOSTTY_DIR" apply "$PATCH"
elif git -C "$GHOSTTY_DIR" apply --reverse --check "$PATCH" 2>/dev/null; then
  echo "  scripts/ghostty.patch: already applied"
elif git -C "$GHOSTTY_DIR" apply --check "$PATCH" 2>/dev/null; then
  git -C "$GHOSTTY_DIR" apply "$PATCH"
  echo "  scripts/ghostty.patch: applied"
else
  echo "error: scripts/ghostty.patch doesn't apply: vendor/ghostty has local changes or an older" >&2
  echo "  ghostty.patch. Fix: git -C vendor/ghostty checkout -- . && scripts/bootstrap.sh" >&2
  exit 1
fi
echo ""

echo "2. Zig $ZIG_VERSION -> .tools/zig"
if [[ -x "$ZIG_DIR/zig" ]] && [[ "$("$ZIG_DIR/zig" version 2>/dev/null)" == "$ZIG_VERSION" ]]; then
  echo "  already there, skipped"
else
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  run curl -fL --proto '=https' -o "$TMP/$ZIG_TARBALL" "$ZIG_URL"
  echo "  verify: sha256 $ZIG_SHA256"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    echo "$ZIG_SHA256  $TMP/$ZIG_TARBALL" | shasum -a 256 -c - >/dev/null \
      || { echo "error: $ZIG_TARBALL does not match the pinned sha256; not using it" >&2; exit 1; }
  fi
  run rm -rf "$ZIG_DIR"
  run mkdir -p "$ZIG_DIR"
  run tar -xJf "$TMP/$ZIG_TARBALL" -C "$ZIG_DIR" --strip-components 1
fi
echo ""

echo "3. GhosttyKit.xcframework (vendor/ghostty/macos/GhosttyKit.xcframework)"
if [[ "$DRY_RUN" -eq 1 ]]; then
  printf '  $ (cd vendor/ghostty &&'; printf ' %q' "$ZIG_DIR/zig" build "${ZIG_FLAGS[@]}"; printf ')\n'
else
  (cd "$GHOSTTY_DIR" && "$ZIG_DIR/zig" build "${ZIG_FLAGS[@]}")
fi
echo ""

FW="$ROOT/App/Frameworks/GhosttyKit.xcframework"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "4. check: $FW resolves to the built xcframework"
  echo ""
  echo "Then: App/scripts/bundle.sh"
  exit 0
fi
[[ -f "$FW/Info.plist" ]] || { echo "error: $FW does not resolve to a built xcframework" >&2; exit 1; }
echo "Done. Next: App/scripts/bundle.sh"
