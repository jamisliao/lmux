#!/bin/bash
# scripts/install-git-hooks.sh [--uninstall]
#
# Opt-in: installs a git pre-push hook in this checkout that runs, before every push,
#   1. Core: swift test
#   2. App:  App/scripts/apptest.sh --quick   (headless app smoke test, ~1 min once built:
#            no window, no focus change; state, sockets and settings are temp)
# and blocks the push if either fails. `git push --no-verify` skips it once.
# Nothing installs this automatically; run it yourself. --uninstall removes it again
# (only if it is the hook this script wrote).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$(git -C "$ROOT" rev-parse --git-path hooks)/pre-push"
case "$HOOK" in /*) ;; *) HOOK="$ROOT/$HOOK" ;; esac
MARK="# lmux pre-push hook (scripts/install-git-hooks.sh)"

if [ "${1:-}" = "--uninstall" ]; then
  if [ -f "$HOOK" ] && grep -qF "$MARK" "$HOOK"; then rm -f "$HOOK"; echo "removed $HOOK"; else echo "no lmux pre-push hook installed"; fi
  exit 0
fi
[ -z "${1:-}" ] || { sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 1; }

if [ -e "$HOOK" ] && ! grep -qF "$MARK" "$HOOK"; then
  echo "error: $HOOK already exists and is not lmux's; move it away first" >&2
  exit 1
fi
mkdir -p "$(dirname "$HOOK")"
cat > "$HOOK" <<EOF
#!/bin/bash
$MARK
# Core swift test + headless app smoke test. Skip once with: git push --no-verify
set -euo pipefail
cd "\$(git rev-parse --show-toplevel)"
echo "pre-push: Core swift test" >&2
(cd Core && swift test >/dev/null 2>&1) || { echo "pre-push: Core tests failed (run: cd Core && swift test)" >&2; exit 1; }
if [ -f App/Frameworks/GhosttyKit.xcframework/Info.plist ]; then
  echo "pre-push: App/scripts/apptest.sh --quick (headless)" >&2
  App/scripts/apptest.sh --quick | grep -E '^(FAIL|RESULT)' >&2 || { echo "pre-push: app smoke test failed (run: App/scripts/apptest.sh --quick)" >&2; exit 1; }
else
  echo "pre-push: no GhosttyKit.xcframework (run scripts/bootstrap.sh); app smoke test skipped" >&2
fi
EOF
chmod +x "$HOOK"
echo "installed $HOOK"
