#!/bin/bash
# release/publish-to-public.sh [--update] [--dry-run] [--replace-initial] [--yes] [--force] [--out DIR]
#
# Pushes a snapshot of this dev tree (sooftware/lmux-dev) to the public repo (sooftware/lmux),
# built on top of release/publish.sh's snapshot export + secret/private-path scan.
#
# Two modes:
#
#   initial (default) — fresh history, ONE commit "Initial commit" (authored as sooftware),
#     force-pushed to replace sooftware/lmux's existing single commit. Because this REPLACES
#     history on the public repo, it only actually pushes when BOTH --replace-initial and --yes
#     are given; otherwise (the default) it prints the exact commands and does nothing.
#
#   --update — clones sooftware/lmux's current main, replaces ALL of its tracked content with a
#     fresh snapshot (so only what release/publish.sh's allowlist ships, same as the initial
#     commit), commits "Sync from dev <short dev sha>", and pushes normally (no force, ordinary
#     fast-forward history). This is for every release after the first.
#
# Either mode always runs release/publish.sh first (--force is forwarded to it), which refuses
# to produce a snapshot if its scan finds anything. --dry-run (the default for the initial mode
# unless --replace-initial --yes are both given; opt-in via the flag for --update) never clones,
# commits, or pushes -- it only prints the snapshot + scan output and the exact git/gh commands a
# real run would execute.
#
# This script NEVER changes sooftware/lmux's visibility (public/private) -- that stays a human
# decision, see release/setup-public-repo.sh.
set -euo pipefail

MODE_UPDATE=0
DRY_RUN=0
REPLACE_INITIAL=0
YES=0
FORCE=0
OUT_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --update) MODE_UPDATE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --replace-initial) REPLACE_INITIAL=1; shift ;;
    --yes) YES=1; shift ;;
    --force) FORCE=1; shift ;;
    --out) OUT_DIR="${2:-}"; [[ -n "$OUT_DIR" ]] || { echo "error: --out needs a value" >&2; exit 1; }; shift 2 ;;
    --out=*) OUT_DIR="${1#*=}"; shift ;;
    -h|--help)
      sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "error: unknown argument: $1" >&2; exit 1 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/release/out/lmux-public}"
PUBLIC_REPO="sooftware/lmux"
AUTHOR_NAME="sooftware"
AUTHOR_EMAIL="sh951011@gmail.com"
SHORT_SHA="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"

echo "== lmux publish-to-public ($([[ $MODE_UPDATE -eq 1 ]] && echo update || echo initial)) =="
echo ""

# --- 1. snapshot + scan (release/publish.sh does the real work; never skipped) -----------
PUBLISH_ARGS=(--out "$OUT_DIR")
[[ "$FORCE" -eq 1 ]] && PUBLISH_ARGS+=(--force)
"$REPO_ROOT/release/publish.sh" "${PUBLISH_ARGS[@]}"
echo ""

if [[ "$MODE_UPDATE" -eq 1 ]]; then
  COMMIT_MSG="Sync from dev $SHORT_SHA"
  echo "-- update: sync $OUT_DIR into $PUBLIC_REPO main --"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    cat <<CMDS
DRY RUN: would run:
  CLONE=\$(mktemp -d)
  GH_TOKEN=\$(gh auth token --user sooftware) gh repo clone $PUBLIC_REPO "\$CLONE"
  rsync -a --delete --exclude=.git "$OUT_DIR"/ "\$CLONE"/
  cd "\$CLONE"
  git add -A
  git -c user.name=$AUTHOR_NAME -c user.email=$AUTHOR_EMAIL commit -m "$COMMIT_MSG"
  GH_TOKEN=\$(gh auth token --user sooftware) git push origin HEAD:main
CMDS
    exit 0
  fi

  CLONE="$(mktemp -d)"
  trap 'rm -rf "$CLONE"' EXIT
  GH_TOKEN="$(gh auth token --user sooftware)" gh repo clone "$PUBLIC_REPO" "$CLONE"
  rsync -a --delete --exclude=.git "$OUT_DIR"/ "$CLONE"/
  (cd "$CLONE" && git add -A)
  if (cd "$CLONE" && git diff --cached --quiet); then
    echo "nothing changed since $PUBLIC_REPO's current main; skipping commit/push"
    exit 0
  fi
  (cd "$CLONE" && git -c user.name="$AUTHOR_NAME" -c user.email="$AUTHOR_EMAIL" commit -q -m "$COMMIT_MSG")
  GH_TOKEN="$(gh auth token --user sooftware)" git -C "$CLONE" push origin HEAD:main
  echo "pushed: $COMMIT_MSG"
else
  COMMIT_MSG="Initial commit"
  echo "-- initial: replace $PUBLIC_REPO's history with one commit from $OUT_DIR --"
  REAL_RUN=0
  [[ "$REPLACE_INITIAL" -eq 1 && "$YES" -eq 1 && "$DRY_RUN" -eq 0 ]] && REAL_RUN=1
  if [[ "$REAL_RUN" -eq 0 ]]; then
    cat <<CMDS
DRY RUN (pass --replace-initial --yes together, with no --dry-run, to actually force-push):
would run:
  TMP=\$(mktemp -d)
  cp -a "$OUT_DIR"/. "\$TMP"/
  cd "\$TMP"
  git init -q
  git add -A
  git -c user.name=$AUTHOR_NAME -c user.email=$AUTHOR_EMAIL commit -m "$COMMIT_MSG"
  git remote add origin https://github.com/$PUBLIC_REPO.git
  GH_TOKEN=\$(gh auth token --user sooftware) git push --force origin HEAD:main
CMDS
    exit 0
  fi

  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  cp -a "$OUT_DIR"/. "$TMP"/
  (cd "$TMP" && git init -q && git add -A && git -c user.name="$AUTHOR_NAME" -c user.email="$AUTHOR_EMAIL" commit -q -m "$COMMIT_MSG")
  (cd "$TMP" && git remote add origin "https://github.com/$PUBLIC_REPO.git")
  GH_TOKEN="$(gh auth token --user sooftware)" git -C "$TMP" push --force origin HEAD:main
  echo "force-pushed: $COMMIT_MSG"
fi
