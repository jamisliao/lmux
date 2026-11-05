#!/bin/bash
# release/setup-public-repo.sh [--dry-run] [--repo OWNER/NAME]
#
# Idempotently configures the PUBLIC lmux repo (default: sooftware/lmux) via `gh api`:
#   - labels: bug, enhancement, ime, performance, claude-code, wontfix-weight, good first issue, docs
#   - private vulnerability reporting (enabled)
#   - Dependabot alerts + automated security updates (enabled)
#   - secret scanning + push protection (only effective on a public repo, or a private one with
#     GitHub Advanced Security; on a private free-tier repo this step fails harmlessly and the
#     script prints what to re-run once the repo goes public)
#   - a branch ruleset on main requiring the CI checks "core" and "app" plus a pull request
#     before merging (on GitHub Free, branch protection / rulesets with required status checks
#     are a public-repo feature; the script detects a private repo and skips this with a note
#     instead of failing)
#
# This script NEVER changes the repo's visibility (public/private) — that's a human decision.
# Every step is safe to re-run: labels are created or updated in place, the rest are checked
# before being (re-)enabled. --dry-run prints exactly what would be called/changed and does
# nothing.
#
# Needs: `gh` authenticated for an account with admin on the target repo. This repo is normally
# owned by the personal `sooftware` account, separate from any work account, so run this as:
#   GH_TOKEN=$(gh auth token --user sooftware) release/setup-public-repo.sh
set -euo pipefail

DRY_RUN=0
REPO="sooftware/lmux"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --repo) REPO="${2:-}"; [[ -n "$REPO" ]] || { echo "error: --repo needs a value" >&2; exit 1; }; shift 2 ;;
    --repo=*) REPO="${1#*=}"; shift ;;
    -h|--help)
      sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "error: unknown argument: $1" >&2; exit 1 ;;
  esac
done

api() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '  $ gh api'; printf ' %q' "$@"; printf '\n'
  else
    gh api "$@"
  fi
}

echo "== lmux public repo setup$([[ $DRY_RUN -eq 1 ]] && echo ' (dry run: nothing is called)') =="
echo "repo: $REPO"
echo ""

# --- visibility (read-only; this script never changes it) ---------------
VISIBILITY="$(gh api "repos/$REPO" --jq .visibility 2>/dev/null || echo unknown)"
echo "visibility: $VISIBILITY (this script never changes it)"
echo ""

# --- 1. labels ------------------------------------------------------------
# name -> color|description
LABELS=(
  "bug|d73a4a|Something isn't working"
  "enhancement|a2eeef|New feature or request"
  "ime|c5def5|Input method / Korean typing"
  "performance|fbca04|App size, CPU, memory, startup time"
  "claude-code|5319e7|Claude Code hooks, agent status, transcripts"
  "wontfix-weight|ffffff|out of scope: mostly weight"
  "good first issue|7057ff|Good for newcomers"
  "docs|0075ca|Documentation"
)
echo "-- labels --"
EXISTING="$(gh api "repos/$REPO/labels" --paginate --jq '.[].name' 2>/dev/null || true)"
for entry in "${LABELS[@]}"; do
  name="${entry%%|*}"
  rest="${entry#*|}"
  color="${rest%%|*}"
  desc="${rest#*|}"
  if printf '%s\n' "$EXISTING" | grep -qxF "$name"; then
    echo "  $name: exists, updating color/description"
    api -X PATCH "repos/$REPO/labels/$(printf '%s' "$name" | sed 's/ /%20/g')" \
      -f new_name="$name" -f color="$color" -f description="$desc" >/dev/null
  else
    echo "  $name: creating"
    api -X POST "repos/$REPO/labels" \
      -f name="$name" -f color="$color" -f description="$desc" >/dev/null
  fi
done
echo ""

# --- 2. private vulnerability reporting -----------------------------------
echo "-- private vulnerability reporting --"
PVR="$(gh api "repos/$REPO/private-vulnerability-reporting" --jq .enabled 2>/dev/null || echo false)"
if [[ "$PVR" == "true" ]]; then
  echo "  already enabled"
else
  echo "  enabling"
  if api -X PUT "repos/$REPO/private-vulnerability-reporting" >/dev/null 2>&1; then
    [[ "$DRY_RUN" -eq 1 ]] || echo "  enabled"
  else
    echo "  WARNING: could not enable (GitHub 404s this on some private repos; re-run once" >&2
    echo "  $REPO is public):" >&2
    echo "    GH_TOKEN=\$(gh auth token --user sooftware) release/setup-public-repo.sh --repo $REPO" >&2
  fi
fi
echo ""

# --- 3. Dependabot alerts + automated security updates ---------------------
echo "-- Dependabot --"
if gh api "repos/$REPO/vulnerability-alerts" >/dev/null 2>&1; then
  echo "  alerts: already enabled"
else
  echo "  alerts: enabling"
  api -X PUT "repos/$REPO/vulnerability-alerts" >/dev/null 2>&1 \
    || echo "  WARNING: could not enable Dependabot alerts (re-run to retry)" >&2
fi
if gh api "repos/$REPO/automated-security-fixes" --jq .enabled 2>/dev/null | grep -qx true; then
  echo "  security updates: already enabled"
else
  echo "  security updates: enabling"
  api -X PUT "repos/$REPO/automated-security-fixes" >/dev/null 2>&1 \
    || echo "  WARNING: could not enable automated security fixes (re-run to retry)" >&2
fi
echo ""

# --- 4. secret scanning + push protection -----------------------------------
# GitHub Advanced Security features: free on public repos, paid on private ones. Attempted
# either way (a private repo with GHAS enabled would still want this); failures are reported
# as a note to re-run rather than aborting the script.
echo "-- secret scanning + push protection --"
if [[ "$DRY_RUN" -eq 1 ]]; then
  api -X PATCH "repos/$REPO" \
    -f 'security_and_analysis[secret_scanning][status]=enabled' \
    -f 'security_and_analysis[secret_scanning_push_protection][status]=enabled'
else
  if gh api -X PATCH "repos/$REPO" \
      -f 'security_and_analysis[secret_scanning][status]=enabled' \
      -f 'security_and_analysis[secret_scanning_push_protection][status]=enabled' >/dev/null 2>&1; then
    echo "  enabled"
  else
    echo "  WARNING: could not enable (needs the repo to be public, or GitHub Advanced Security" >&2
    echo "  on a private repo). Once $REPO is public, re-run:" >&2
    echo "    GH_TOKEN=\$(gh auth token --user sooftware) release/setup-public-repo.sh --repo $REPO" >&2
  fi
fi
echo ""

# --- 5. branch ruleset on main: require "core" + "app" checks, require a PR ---
# Branch protection / rulesets with required status checks are a public-repo feature on GitHub
# Free; a private repo on a free plan can't have this, so detect and skip with a note instead
# of failing noisily.
echo "-- branch ruleset: main requires core + app checks, PRs required --"
if [[ "$VISIBILITY" != "public" ]]; then
  echo "  skipped: $REPO is $VISIBILITY. Branch rulesets with required status checks need a"
  echo "  public repo (or a paid plan) on GitHub Free. Once it's public, re-run:"
  echo "    GH_TOKEN=\$(gh auth token --user sooftware) release/setup-public-repo.sh --repo $REPO"
else
  RULESET_NAME="require-ci-and-pr"
  EXISTING_ID="$(gh api "repos/$REPO/rulesets" --jq ".[] | select(.name == \"$RULESET_NAME\") | .id" 2>/dev/null || true)"
  RULESET_JSON=$(cat <<'JSON'
{
  "name": "require-ci-and-pr",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [ { "actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always" } ],
  "conditions": { "ref_name": { "include": ["refs/heads/main"], "exclude": [] } },
  "rules": [
    { "type": "pull_request", "parameters": { "required_approving_review_count": 0 } },
    { "type": "required_status_checks", "parameters": {
        "strict_required_status_checks_policy": true,
        "required_status_checks": [
          { "context": "Core (swift test)" },
          { "context": "App (bundle, apptest, imetest, real IME, idle budget)" }
        ]
      } }
  ]
}
JSON
)
  if [[ "$DRY_RUN" -eq 1 ]]; then
    if [[ -n "$EXISTING_ID" ]]; then
      printf '  $ gh api -X PUT repos/%s/rulesets/%s --input - <<<ruleset JSON above\n' "$REPO" "$EXISTING_ID"
    else
      printf '  $ gh api -X POST repos/%s/rulesets --input - <<<ruleset JSON above\n' "$REPO"
    fi
  else
    if [[ -n "$EXISTING_ID" ]]; then
      echo "  $RULESET_NAME: exists (id $EXISTING_ID), updating"
      echo "$RULESET_JSON" | gh api -X PUT "repos/$REPO/rulesets/$EXISTING_ID" --input - >/dev/null \
        || echo "  WARNING: could not update ruleset (re-run to retry)" >&2
    else
      echo "  $RULESET_NAME: creating"
      echo "$RULESET_JSON" | gh api -X POST "repos/$REPO/rulesets" --input - >/dev/null \
        || echo "  WARNING: could not create ruleset (re-run to retry)" >&2
    fi
  fi
fi
echo ""

echo "Done.$([[ "$DRY_RUN" -eq 1 ]] && echo ' (dry run: nothing was actually called)')"
