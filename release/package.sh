#!/bin/bash
# release/package.sh [--version X.Y.Z]
#
# Takes an already-built App/build/lmux.app (built by App/scripts/bundle.sh),
# stamps a version into a COPY, signs it, notarizes it if requested, and
# produces a zip, a dmg, and sha256 sums under release/out/, plus an
# unversioned copy of the dmg (lmux-arm64.dmg) for the README's
# releases/latest/download link.
#
# This script never touches App/build/lmux.app itself and never runs
# `swift build` or App/scripts/bundle.sh — build the app first.
#
# Env:
#   LMUX_SIGN_IDENTITY   "Developer ID Application: Name (TEAMID)" from
#                        `security find-identity -v -p codesigning`.
#                        Unset => ad-hoc sign (codesign -s -), with a loud
#                        warning that Gatekeeper will block the download for
#                        anyone else.
#   LMUX_NOTARY_PROFILE  xcrun notarytool keychain profile name (see
#                        `xcrun notarytool store-credentials`). Notarizes and
#                        staples the app and the dmg. Requires
#                        LMUX_SIGN_IDENTITY — Apple will not notarize an
#                        ad-hoc signed app.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: release/package.sh [--version X.Y.Z]

Reads App/build/lmux.app, stamps the version (or keeps the one already in
Info.plist if --version is omitted), signs, optionally notarizes, and writes
release/out/lmux-<version>-arm64.{zip,dmg} plus a .sha256.txt, and
lmux-arm64.dmg (the same dmg under a name that never changes).

Env:
  LMUX_SIGN_IDENTITY    Developer ID Application identity to sign with.
  LMUX_NOTARY_PROFILE   notarytool keychain profile to submit+staple with.
EOF
}

VERSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2:-}"
      [[ -n "$VERSION" ]] || { echo "error: --version needs a value" >&2; exit 1; }
      shift 2
      ;;
    --version=*)
      VERSION="${1#*=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -n "$VERSION" && ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: --version must look like X.Y.Z (got: $VERSION)" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_SRC="$REPO_ROOT/App/build/lmux.app"
OUT_DIR="$REPO_ROOT/release/out"
PLISTBUDDY=/usr/libexec/PlistBuddy

if [[ ! -d "$APP_SRC" ]]; then
  echo "error: $APP_SRC not found." >&2
  echo "Build it first:" >&2
  echo "  App/scripts/bundle.sh" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
WORK_APP="$OUT_DIR/lmux.app"
rm -rf "$WORK_APP"
# Work on a copy — App/build/lmux.app (and the agents that may rebuild it) are
# never touched by this script.
cp -R "$APP_SRC" "$WORK_APP"

PLIST="$WORK_APP/Contents/Info.plist"
if [[ -n "$VERSION" ]]; then
  "$PLISTBUDDY" -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
  "$PLISTBUDDY" -c "Set :CFBundleVersion $VERSION" "$PLIST"
else
  VERSION="$("$PLISTBUDDY" -c "Print :CFBundleShortVersionString" "$PLIST")"
  echo "No --version given; using the version already in Info.plist: $VERSION"
fi
echo "Packaging lmux $VERSION"

# Nested binaries, inside-out (bundle layout from App/scripts/bundle.sh):
#   Contents/Resources/bin/lmux-hook  (Core's lmux-hook, Claude Code hook client)
#   Contents/Resources/bin/lmux       (lmux-cli, the `lmux` command on PATH in panes)
#   Contents/MacOS/lmux               (the app itself, signed last; no --deep, which Apple deprecates:
#                                      each nested binary is signed explicitly first)
# There is no separate index-helper binary to sign: per App/README.md
# ("History (R12)"), session indexing/archiving runs as `lmux --lmux-index`,
# a short-lived child process of the SAME Contents/MacOS/lmux executable, so
# signing that executable covers it.
NESTED_BINARIES=(
  "$WORK_APP/Contents/Resources/bin/lmux-hook"
  "$WORK_APP/Contents/Resources/bin/lmux"
)
for bin in "${NESTED_BINARIES[@]}"; do
  if [[ ! -f "$bin" ]]; then
    echo "error: expected nested binary not found: $bin" >&2
    exit 1
  fi
done

# Entitlements (release/entitlements.plist): only the hardened-runtime resource-access ones a terminal
# needs so programs running in a pane can get a TCC prompt (camera, microphone, Apple Events, contacts,
# calendars, location, photos; same set as Ghostty's). Without them the hardened runtime denies those
# requests silently, whatever the Info.plist usage strings say. GhosttyKit is linked statically
# (App/Package.swift: .binaryTarget), so there are no bundled dylibs and no library-validation, JIT or
# unsigned-memory exception. Nested helpers are signed without entitlements.
ENTITLEMENTS="$REPO_ROOT/release/entitlements.plist"
# (Expanded as ${ENTITLEMENTS_ARGS[@]+...}: macOS's bash 3.2 under `set -u` dies on an empty "${a[@]}".)
ENTITLEMENTS_ARGS=()
if [[ -f "$ENTITLEMENTS" ]]; then
  ENTITLEMENTS_ARGS=(--entitlements "$ENTITLEMENTS")
fi

SIGN_ID="${LMUX_SIGN_IDENTITY:-}"
if [[ -n "$SIGN_ID" ]]; then
  echo "Signing with Developer ID: $SIGN_ID"
  for bin in "${NESTED_BINARIES[@]}"; do
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$bin"
  done
  codesign --force --options runtime --timestamp ${ENTITLEMENTS_ARGS[@]+"${ENTITLEMENTS_ARGS[@]}"} --sign "$SIGN_ID" "$WORK_APP"
else
  {
    echo ""
    echo "########################################################################"
    echo "# WARNING: LMUX_SIGN_IDENTITY is not set — ad-hoc signing only.       #"
    echo "# Gatekeeper WILL block this build for anyone who downloads it: macOS #"
    echo "# will refuse to open it (\"is damaged\" / \"cannot be opened\") until   #"
    echo "# they right-click > Open, or run xattr -dr on it.                    #"
    echo "# See release/RELEASING.md before doing a public release.             #"
    echo "########################################################################"
    echo ""
  } >&2
  for bin in "${NESTED_BINARIES[@]}"; do
    codesign --force --sign - "$bin"
  done
  codesign --force --sign - "$WORK_APP"
fi

codesign --verify --deep --strict --verbose=2 "$WORK_APP"

if [[ -n "${LMUX_NOTARY_PROFILE:-}" ]]; then
  if [[ -z "$SIGN_ID" ]]; then
    echo "error: LMUX_NOTARY_PROFILE is set but LMUX_SIGN_IDENTITY is not. Apple rejects ad-hoc signed apps for notarization." >&2
    exit 1
  fi
  NOTARIZE_ZIP="$OUT_DIR/.lmux-notarize-submit.zip"
  rm -f "$NOTARIZE_ZIP"
  ditto -c -k --keepParent "$WORK_APP" "$NOTARIZE_ZIP"
  echo "Submitting to notarytool (profile: $LMUX_NOTARY_PROFILE)..."
  xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile "$LMUX_NOTARY_PROFILE" --wait
  rm -f "$NOTARIZE_ZIP"
  echo "Stapling the notarization ticket to the app..."
  xcrun stapler staple "$WORK_APP"
fi

ZIP_NAME="lmux-$VERSION-arm64.zip"
DMG_NAME="lmux-$VERSION-arm64.dmg"
SHA_NAME="lmux-$VERSION-arm64.sha256.txt"
LATEST_DMG_NAME="lmux-arm64.dmg"
rm -f "$OUT_DIR/$ZIP_NAME" "$OUT_DIR/$DMG_NAME" "$OUT_DIR/$SHA_NAME" "$OUT_DIR/$LATEST_DMG_NAME"

ditto -c -k --keepParent "$WORK_APP" "$OUT_DIR/$ZIP_NAME"

DMG_STAGE="$(mktemp -d)"
trap 'rm -rf "$DMG_STAGE"' EXIT
cp -R "$WORK_APP" "$DMG_STAGE/lmux.app"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -volname "lmux" -srcfolder "$DMG_STAGE" -ov -format UDZO "$OUT_DIR/$DMG_NAME" >/dev/null

# The dmg is its own notarization subject: built from the already-stapled app above, signed with the
# Developer ID, submitted itself, then stapled (stapling a dmg that was never submitted fails with
# Error 65 "Record not found").
if [[ -n "$SIGN_ID" ]]; then
  echo "Signing the dmg..."
  codesign --force --timestamp --sign "$SIGN_ID" "$OUT_DIR/$DMG_NAME"
fi
if [[ -n "${LMUX_NOTARY_PROFILE:-}" && -n "$SIGN_ID" ]]; then
  echo "Submitting the dmg to notarytool (profile: $LMUX_NOTARY_PROFILE)..."
  xcrun notarytool submit "$OUT_DIR/$DMG_NAME" --keychain-profile "$LMUX_NOTARY_PROFILE" --wait
  echo "Stapling the notarization ticket to the dmg..."
  xcrun stapler staple "$OUT_DIR/$DMG_NAME"
fi

( cd "$OUT_DIR" && shasum -a 256 "$ZIP_NAME" "$DMG_NAME" > "$SHA_NAME" )
# Same bytes as the versioned dmg, so releases/latest/download/lmux-arm64.dmg always gets the
# newest one. The cask keeps using the versioned zip.
cp "$OUT_DIR/$DMG_NAME" "$OUT_DIR/$LATEST_DMG_NAME"

echo ""
echo "Done. Output in $OUT_DIR:"
ls -la "$OUT_DIR/$ZIP_NAME" "$OUT_DIR/$DMG_NAME" "$OUT_DIR/$LATEST_DMG_NAME" "$OUT_DIR/$SHA_NAME"
echo ""
cat "$OUT_DIR/$SHA_NAME"
