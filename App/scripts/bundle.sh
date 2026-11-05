#!/bin/bash
# Build lmux with SwiftPM and assemble a proper lmux.app bundle.
#   App/scripts/bundle.sh [debug|release]   (default: release)
# Output: App/build/lmux.app
set -euo pipefail

CONFIG="${1:-release}"
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GHOSTTY="$APP_DIR/../vendor/ghostty"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"

cd "$APP_DIR"
# vendor/ghostty must carry scripts/ghostty.patch (idle GPU release). Checked only on a git checkout
# (CI's cache restores just the built xcframework); a release build refuses to go without it.
if [ -d "$GHOSTTY/.git" ] && ! git -C "$GHOSTTY" apply --reverse --check "$APP_DIR/../scripts/ghostty.patch" 2>/dev/null; then
  msg="vendor/ghostty lacks scripts/ghostty.patch: git -C vendor/ghostty checkout -- . && scripts/bootstrap.sh"
  if [ "$CONFIG" = release ]; then echo "error: $msg" >&2; exit 1; fi
  echo "warning: $msg" >&2
fi
swift build -c "$CONFIG" --product lmux
swift build -c "$CONFIG" --product lmux-cli
BINDIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BINDIR/lmux"
# AppKit keeps old behavior for a binary linked against an old SDK (⌘-drag in the sidebar breaks).
# A toolchain without a full Xcode can record SDK 14.0 here whatever SDK it compiled with.
SDK="$(otool -l "$BIN" | awk '/LC_BUILD_VERSION/ { b = 1 } b && $1 == "sdk" { print $2; exit }')"
if [ "${SDK%%.*}" -lt 26 ] 2>/dev/null || [ -z "$SDK" ]; then
  echo "error: lmux was built against SDK ${SDK:-unknown}; set DEVELOPER_DIR to a full Xcode (26 or later)" >&2
  exit 1
fi
# lmux-hook (Claude Code hook client) comes from the Core package.
(cd "$APP_DIR/../Core" && swift build -c "$CONFIG" --product lmux-hook)
HOOK="$(cd "$APP_DIR/../Core" && swift build -c "$CONFIG" --show-bin-path)/lmux-hook"

OUT="$APP_DIR/build/lmux.app"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources/ghostty/themes" "$OUT/Contents/Resources/Fonts" \
         "$OUT/Contents/Resources/bin"
cp "$BIN" "$OUT/Contents/MacOS/lmux"
# Helpers on PATH inside panes: `lmux` (CLI) and `lmux-hook` (installed into Claude Code settings).
cp "$BINDIR/lmux-cli" "$OUT/Contents/Resources/bin/lmux"
cp "$HOOK" "$OUT/Contents/Resources/bin/lmux-hook"
cp "$APP_DIR/../assets/AppIcon.icns" "$OUT/Contents/Resources/AppIcon.icns"

# libghostty resources. Ghostty finds them by looking for
# Contents/Resources/terminfo/78/xterm-ghostty next to the executable.
cp -R "$GHOSTTY/zig-out/share/terminfo" "$OUT/Contents/Resources/terminfo"
cp -R "$GHOSTTY/zig-out/share/ghostty/shell-integration" "$OUT/Contents/Resources/ghostty/"
# Only the default theme pair is bundled (the full set is ~3.2 MB / 800+ files).
cp "$APP_DIR/Resources/themes/"* "$OUT/Contents/Resources/ghostty/themes/"
# Fonts as TTF (CoreText maps a TTF; a WOFF is inflated into the heap, ~33 MB for the two faces).
for f in "$APP_DIR/Resources/Fonts/"*; do
  case "$f" in
    *.woff) python3 "$APP_DIR/scripts/woff-to-ttf.py" "$f" "$OUT/Contents/Resources/Fonts/$(basename "${f%.woff}").ttf" ;;
    *) cp "$f" "$OUT/Contents/Resources/Fonts/" ;;
  esac
done
xcrun swift "$APP_DIR/scripts/check-fonts.swift" "$OUT/Contents/Resources/Fonts"
cp "$APP_DIR/../LICENSE" "$APP_DIR/THIRD_PARTY_NOTICES.md" "$OUT/Contents/Resources/"

cat > "$OUT/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>lmux</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleIdentifier</key><string>dev.lmux.app</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>lmux</string>
	<key>CFBundleDisplayName</key><string>lmux</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>0.0.1</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>NSHumanReadableCopyright</key><string>Copyright © 2026 Soohwan Kim. MIT License.</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>NSSupportsAutomaticGraphicsSwitching</key><true/>
	<!-- TCC prompts for programs running in a pane are attributed to lmux; without these keys macOS
	     denies (or kills) them silently. Same set and wording as Ghostty's macOS app. -->
	<key>NSAppleEventsUsageDescription</key><string>A program running in lmux would like to use AppleScript.</string>
	<key>NSAudioCaptureUsageDescription</key><string>A program running in lmux would like to access your system's audio.</string>
	<key>NSBluetoothAlwaysUsageDescription</key><string>A program running in lmux would like to use Bluetooth.</string>
	<key>NSCalendarsUsageDescription</key><string>A program running in lmux would like to access your Calendar.</string>
	<key>NSCameraUsageDescription</key><string>A program running in lmux would like to use the camera.</string>
	<key>NSContactsUsageDescription</key><string>A program running in lmux would like to access your Contacts.</string>
	<key>NSLocalNetworkUsageDescription</key><string>A program running in lmux would like to access the local network.</string>
	<key>NSLocationUsageDescription</key><string>A program running in lmux would like to access your location information.</string>
	<key>NSMicrophoneUsageDescription</key><string>A program running in lmux would like to use your microphone.</string>
	<key>NSMotionUsageDescription</key><string>A program running in lmux would like to access motion data.</string>
	<key>NSPhotoLibraryUsageDescription</key><string>A program running in lmux would like to access your Photo Library.</string>
	<key>NSRemindersUsageDescription</key><string>A program running in lmux would like to access your reminders.</string>
	<key>NSSpeechRecognitionUsageDescription</key><string>A program running in lmux would like to use speech recognition.</string>
	<key>NSSystemAdministrationUsageDescription</key><string>A program running in lmux requires elevated privileges.</string>
</dict>
</plist>
PLIST

# Release: drop local symbols from the binaries (-3.7 MB on lmux). Crash reports from the bundle
# then name few lmux functions: symbolicate them against the unstripped build output (same UUID),
# e.g. `atos -o App/.build/release/lmux -l <load address> <addresses>`. Before signing, which
# covers the result.
if [ "$CONFIG" = release ]; then
  strip -x "$OUT/Contents/MacOS/lmux" "$OUT/Contents/Resources/bin/lmux" "$OUT/Contents/Resources/bin/lmux-hook"
fi

# Ad-hoc sign so TCC / input methods treat it as a stable app identity.
codesign --force --sign - "$OUT" >/dev/null 2>&1 || true
echo "$OUT"
