#!/bin/bash
# Put a GitHub macOS runner's display settings where a default Mac has them, and print what the jobs
# run on (the logs then explain a display-dependent result). CI only: it changes the logged-in user's
# accessibility settings, so it refuses to run unless GITHUB_ACTIONS=true (never on a developer's Mac).
#
#   .github/scripts/runner-display.sh
set -uo pipefail
if [ "${GITHUB_ACTIONS:-}" != "true" ]; then
  echo "runner-display.sh: refusing to run outside GitHub Actions (GITHUB_ACTIONS != true)" >&2
  exit 2
fi

# The runner image turns Reduce Transparency on; lmux's sidebar is then opaque by design, and the
# real-window polish checks look at the translucent one a default Mac shows.
defaults write com.apple.universalaccess reduceTransparency -bool false \
  || echo "::warning::could not turn Reduce Transparency off"

echo "== accessibility (com.apple.universalaccess)"
defaults read com.apple.universalaccess 2>&1 | grep -iE 'reduce|contrast|differentiate' || echo "(no reduce/contrast keys)"
echo "== displays"
system_profiler SPDisplaysDataType 2>/dev/null | grep -iE 'resolution|retina|main display' || true
echo "== keyboard layout"
defaults read com.apple.HIToolbox AppleSelectedInputSources 2>/dev/null | grep -E 'Layout Name|Input Mode|Bundle ID' || true
echo "== macOS"
sw_vers
exit 0
