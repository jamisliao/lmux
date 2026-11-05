#!/bin/bash
# release/check.sh <path-to-.app|.zip|.dmg>
#
# Verifies a packaged lmux artifact produced by release/package.sh:
#   - codesign --verify --deep --strict  (signature integrity)
#   - spctl -a -vv                       (Gatekeeper assessment)
#   - stapler validate                   (notarization ticket, if any)
#   - lipo -info                         (architectures, for the app
#                                          executable and the nested binaries)
#   - for a .dmg, the dmg itself too: its signature (must verify when present),
#     spctl -a -t open --context context:primary-signature, stapler validate
set -euo pipefail

usage() {
  echo "Usage: release/check.sh <path-to-.app|.zip|.dmg>" >&2
}

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi
TARGET="$1"
if [[ ! -e "$TARGET" ]]; then
  echo "error: $TARGET not found" >&2
  exit 1
fi

WORKDIR=""
MOUNT_DIR=""
cleanup() {
  if [[ -n "$MOUNT_DIR" ]]; then
    hdiutil detach "$MOUNT_DIR" -quiet 2>/dev/null || true
  fi
  if [[ -n "$WORKDIR" ]]; then
    rm -rf "$WORKDIR"
  fi
}
trap cleanup EXIT

APP_PATH=""
case "$TARGET" in
  *.app)
    APP_PATH="$TARGET"
    ;;
  *.zip)
    WORKDIR="$(mktemp -d)"
    ditto -x -k "$TARGET" "$WORKDIR"
    APP_PATH="$(find "$WORKDIR" -maxdepth 1 -name '*.app' | head -1)"
    ;;
  *.dmg)
    WORKDIR="$(mktemp -d)"
    MOUNT_DIR="$WORKDIR/mnt"
    mkdir -p "$MOUNT_DIR"
    hdiutil attach "$TARGET" -mountpoint "$MOUNT_DIR" -nobrowse -readonly -quiet
    APP_PATH="$(find "$MOUNT_DIR" -maxdepth 1 -name '*.app' | head -1)"
    ;;
  *)
    echo "error: unsupported target (expected .app, .zip, or .dmg): $TARGET" >&2
    exit 1
    ;;
esac

if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
  echo "error: could not find a .app inside $TARGET" >&2
  exit 1
fi

echo "== codesign --verify --deep --strict =="
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo ""
echo "== spctl -a -vv (Gatekeeper assessment) =="
echo "Expected to FAIL (e.g. \"rejected\" / source=Unnotarized Developer ID, or"
echo "no usable signature) unless this was signed with a Developer ID AND"
echo "notarized+stapled — an ad-hoc signed build always fails this check."
set +e
spctl -a -vv "$APP_PATH"
SPCTL_STATUS=$?
set -e
if [[ $SPCTL_STATUS -ne 0 ]]; then
  echo "(spctl exited $SPCTL_STATUS — see note above; this is not treated as a failure here)"
fi

echo ""
echo "== stapler validate =="
set +e
xcrun stapler validate "$APP_PATH"
STAPLE_STATUS=$?
set -e
if [[ $STAPLE_STATUS -ne 0 ]]; then
  echo "(no valid notarization ticket is stapled — expected unless package.sh ran with"
  echo " LMUX_SIGN_IDENTITY and LMUX_NOTARY_PROFILE set)"
fi

echo ""
echo "== lipo -info (architectures) =="
EXECUTABLE="$APP_PATH/Contents/MacOS/lmux"
if [[ -f "$EXECUTABLE" ]]; then
  echo "Contents/MacOS/lmux:"
  lipo -info "$EXECUTABLE"
else
  echo "warning: $EXECUTABLE not found" >&2
fi
for name in lmux lmux-hook; do
  bin="$APP_PATH/Contents/Resources/bin/$name"
  if [[ -f "$bin" ]]; then
    echo "Contents/Resources/bin/$name:"
    lipo -info "$bin"
  fi
done

if [[ "$TARGET" == *.dmg ]]; then
  echo ""
  echo "== the dmg itself =="
  if codesign -d "$TARGET" >/dev/null 2>&1; then
    codesign --verify --strict --verbose=2 "$TARGET"
  else
    echo "(the dmg is not signed — expected only without LMUX_SIGN_IDENTITY)"
  fi
  set +e
  spctl -a -t open --context context:primary-signature -vv "$TARGET"
  DMG_SPCTL=$?
  xcrun stapler validate "$TARGET"
  DMG_STAPLE=$?
  set -e
  [[ $DMG_SPCTL -eq 0 ]] || echo "(spctl on the dmg exited $DMG_SPCTL — informational, as for the app)"
  [[ $DMG_STAPLE -eq 0 ]] || echo "(no notarization ticket stapled to the dmg — expected unless notarized)"
fi

echo ""
echo "codesign verification passed. (spctl/stapler results above are informational — see notes.)"
