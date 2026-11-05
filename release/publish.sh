#!/bin/bash
# release/publish.sh [--dry-run] [--force] [--out DIR]
#
# Exports a clean snapshot of this dev tree (sooftware/lmux-dev) into a fresh
# directory, meant to become the single initial commit of the public repo
# (sooftware/lmux) — no dev history, no scratch files, no local/secret paths.
#
# This script NEVER runs git, NEVER creates or pushes a GitHub repo, and
# NEVER touches the source tree. It only reads from the repo and writes to
# the output directory (which it wipes and recreates fresh).
#
# What ships (explicit allowlist, nothing else):
#   App/, Core/, assets/, .github/ (workflows, actions, issue templates),
#   docs/ (if present), README.md, CONTRIBUTING.md, SECURITY.md, LICENSE*
#   (if present), THIRD_PARTY_NOTICES* (if present at the repo root — App's
#   own copy already ships inside App/), release/ (this directory, minus its
#   own generated output), GHOSTTY_COMMIT + scripts/bootstrap.sh (build from
#   source: clones Ghostty at that commit, fetches Zig, builds the
#   xcframework that App/Frameworks/ links to), scripts/bench.sh +
#   scripts/BENCH.md + scripts/install-git-hooks.sh. lmux is "light mux" on
#   purpose — keep this list minimal; don't add a directory just because it
#   exists in the dev tree.
# Build artifacts (.build, .omc, .tools, App/build, DerivedData, xcuserdata,
# .swiftpm, .DS_Store, .git) are stripped from every allowlisted directory,
# and so is assets/fonts/*.ttc (the upstream D2Coding font, 8MB: the app
# bundles WOFFs made from it, and App/scripts/make-fonts.py downloads the
# pinned official release when the .ttc isn't there).
# Everything else at the repo root is left out because it is not in the
# allowlist above — notably the dev-only docs (PLAN.md, REQUIREMENTS.md,
# DESIGN.md, design/: internal planning/UX notes, not useful to the public
# and not kept in sync with what shipped), vendor/, Wiki/ (the session-wiki
# feature was dropped), and the rest of the top-level scripts/ (bench-compare.sh
# is a maintainer tool for the README's benchmark table, not something a
# contributor needs to build or test lmux).
#
# Before writing anything, it scans the text files that would ship (binary
# files are skipped: grep -I) for secrets and private/local paths: /Users/<name>
# (except the fixture paths in PATH_FIXTURES below), /private/tmp/claude-,
# API tokens, private keys, and email addresses (RFC 2606 *.example domains
# are treated as intentional test fixtures, not findings). --dry-run always
# prints the file list and the scan results and exits 0 without writing
# anything. A real run (no --dry-run) aborts with the findings printed
# unless --force is passed, since only a human can tell a real leak from a
# test fixture.
set -euo pipefail

DRY_RUN=0
FORCE=0
OUT_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --force) FORCE=1; shift ;;
    --out) OUT_DIR="${2:-}"; [[ -n "$OUT_DIR" ]] || { echo "error: --out needs a value" >&2; exit 1; }; shift 2 ;;
    --out=*) OUT_DIR="${1#*=}"; shift ;;
    -h|--help)
      sed -n '2,44p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "error: unknown argument: $1" >&2; exit 1 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/release/out/lmux-public}"

# --- 1. allowlist -----------------------------------------------------
# Top-level entries to copy, if present. "LICENSE*" and "THIRD_PARTY_NOTICES*"
# are globbed at the repo root; everything else is a fixed name.
ALLOW_DIRS=(App Core assets release .github docs skills)
ALLOW_FILES=(README.md README.ja.md README.zh-CN.md README.zh-TW.md README.ko.md README.es.md README.de.md README.fr.md README.it.md README.pt-BR.md README.ru.md README.tr.md README.vi.md .gitignore CONTRIBUTING.md SECURITY.md GHOSTTY_COMMIT scripts/bootstrap.sh scripts/ghostty.patch scripts/bench.sh scripts/bench-compare.sh scripts/BENCH.md scripts/install-git-hooks.sh scripts/test-local.sh)

RSYNC_EXCLUDES=(
  --exclude=.build --exclude=.omc --exclude=.tools --exclude=.swiftpm
  --exclude=DerivedData --exclude=xcuserdata --exclude='*.xcuserstate'
  --exclude=.DS_Store --exclude=.git
  --exclude=build
  --exclude=out
)

echo "== lmux public snapshot =="
echo "source: $REPO_ROOT"
echo "output: $OUT_DIR"
echo ""

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

for d in "${ALLOW_DIRS[@]}"; do
  if [[ -d "$REPO_ROOT/$d" ]]; then
    mkdir -p "$STAGE/$d"
    rsync -a "${RSYNC_EXCLUDES[@]}" "$REPO_ROOT/$d/" "$STAGE/$d/"
  else
    echo "note: $d/ not present, skipping"
  fi
done

for f in "${ALLOW_FILES[@]}"; do
  if [[ -f "$REPO_ROOT/$f" ]]; then
    mkdir -p "$(dirname "$STAGE/$f")"
    cp -p "$REPO_ROOT/$f" "$STAGE/$f"
  else
    echo "note: $f not present, skipping"
  fi
done

LICENSE_FOUND=0
for f in "$REPO_ROOT"/LICENSE*; do
  [[ -f "$f" ]] || continue
  cp "$f" "$STAGE/$(basename "$f")"
  LICENSE_FOUND=1
done
if [[ "$LICENSE_FOUND" -eq 0 ]]; then
  echo ""
  echo "WARNING: no LICENSE file at the repo root. README.md's badge claims MIT —" >&2
  echo "add a LICENSE file before the first public release." >&2
  echo ""
fi

for f in "$REPO_ROOT"/THIRD_PARTY_NOTICES*; do
  [[ -f "$f" ]] || continue
  cp "$f" "$STAGE/$(basename "$f")"
done
# App/THIRD_PARTY_NOTICES.md (Ghostty attribution) already ships via App/.

# Never ship the snapshot staging area or a previous publish inside itself.
rm -rf "$STAGE/release/out"
# The upstream font .ttc: make-fonts.py fetches the pinned release instead.
rm -f "$STAGE"/assets/fonts/*.ttc
rmdir "$STAGE/assets/fonts" 2>/dev/null || true

# --- 2. file list -------------------------------------------------------
echo "-- files that would ship ($(find "$STAGE" -type f | wc -l | tr -d ' ') total) --"
( cd "$STAGE" && find . -type f | sed 's|^\./||' | sort )
echo ""

# --- 3. secret / private-path scan --------------------------------------
# RFC 2606 reserved example domains are treated as intentional fixtures
# (e.g. Core's own secret-redaction-adjacent tests use foo@bar.example
# addresses, AWS's own docs example key, etc).
#
# release/ itself is excluded from the *scan* (but still ships): these
# scripts necessarily contain the literal pattern strings they search for
# (ghp_, sk-ant-, /private/tmp/claude-, example /Users/ paths in comments),
# which would otherwise match every single run.
EXAMPLE_DOMAIN_RE='@[A-Za-z0-9.-]+\.(example|example\.(com|org|net))$'
# Made-up home directories that tests use as fixtures (a cwd, a transcript path, an
# inherited HOME). Exactly these names, nothing longer: /Users/me2 or /Users/xavier
# is still a finding.
PATH_FIXTURES=(/Users/me /Users/x)

SCAN_TARGETS=()
while IFS= read -r -d '' p; do
  SCAN_TARGETS+=("${p#"$STAGE"/}")
done < <(find "$STAGE" -mindepth 1 -maxdepth 1 -not -name release -print0)

# Text files only (-I: binaries such as fonts and GIFs are skipped), paths relative to the snapshot.
FINDINGS=0
report() {
  local label="$1"; shift
  local matches
  matches="$(cd "$STAGE" && "$@" "${SCAN_TARGETS[@]}" 2>/dev/null || true)"
  if [[ -n "$matches" ]]; then
    echo "-- $label --"
    echo "$matches"
    echo ""
    FINDINGS=$((FINDINGS + 1))
  fi
}

# A line is a finding if a /Users/<name> path is left once the fixture paths are cut out.
user_paths() {
  local fixtures
  fixtures="$(printf '%s|' "${PATH_FIXTURES[@]#/Users/}")"
  grep -rnIE '/Users/[A-Za-z0-9_.-]+' "$@" | FIX="${fixtures%|}" perl -ne '
    my ($loc, $text) = /^([^:]*:[0-9]+:)(.*)$/s or next;
    $text =~ s{/Users/(?:$ENV{FIX})(?![A-Za-z0-9_.-])}{}g;
    print if $text =~ m{/Users/[A-Za-z0-9_.-]+};'
}
report "local user paths (/Users/<name>, fixtures ${PATH_FIXTURES[*]} allowed)" user_paths

# A real leaked scratchpad path has a literal uid/pid right after "claude-" (e.g.
# /private/tmp/claude-501/...). Code that builds the same prefix at runtime, e.g.
# App/scripts/e2etest.sh's "/private/tmp/claude-$(id -u)" (looking up a sandboxed Claude Code
# session's own transcript dir), has a non-digit there and is not a finding.
report "scratchpad paths (/private/tmp/claude-<digits>...)" \
  grep -rnIE 'private/tmp/claude-[0-9]'

report "possible API tokens / private keys" \
  grep -rnIE '(ghp_|gho_|ghu_|ghs_|ghr_|github_pat_|sk-ant-|sk-live-|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{20,}|xox[baprs]-[0-9A-Za-z-]+)[A-Za-z0-9_-]*|-----BEGIN [A-Z ]*PRIVATE KEY-----'

EMAIL_HITS="$(cd "$STAGE" && grep -rIEoh '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "${SCAN_TARGETS[@]}" 2>/dev/null | sort -u | grep -vE "$EXAMPLE_DOMAIN_RE" || true)"
if [[ -n "$EMAIL_HITS" ]]; then
  echo "-- email addresses (review: is this the intended public author?) --"
  echo "$EMAIL_HITS"
  echo ""
  FINDINGS=$((FINDINGS + 1))
fi

if [[ "$FINDINGS" -eq 0 ]]; then
  echo "scan: no findings."
else
  echo "scan: $FINDINGS finding group(s) above."
fi
echo ""

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "DRY RUN: nothing written. (run again without --dry-run to publish; add --force to"
  echo "proceed despite the findings above, once you've confirmed they're expected.)"
  exit 0
fi

if [[ "$FINDINGS" -gt 0 && "$FORCE" -ne 1 ]]; then
  echo "error: refusing to publish — the scan above found $FINDINGS group(s)." >&2
  echo "Fix the source, or re-run with --force once you've confirmed every finding is" >&2
  echo "a known fixture (e.g. a test using fake tokens or *.example addresses) rather" >&2
  echo "than a real leak." >&2
  exit 1
fi

rm -rf "$OUT_DIR"
mkdir -p "$(dirname "$OUT_DIR")"
mv "$STAGE" "$OUT_DIR"
trap - EXIT

echo "Wrote snapshot to $OUT_DIR"
echo ""
echo "Next (not run by this script): release/publish-to-public.sh (first release) or"
echo "release/publish-to-public.sh --update (later syncs) — see release/RELEASING.md"
