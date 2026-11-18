# Sourced by the scripts that run `swift build` (bundle, apptest, imetest, e2e, readme, codexreal).
#
# Swift 6.4's default build system links without telling ld the SDK version, so LC_BUILD_VERSION
# records the deployment target (sdk 14.0) and AppKit keeps its old behavior for the binary
# (⌘-drag in the sidebar breaks; bundle.sh refuses it). Every `swift build` here passes the
# SDK version itself. 14.0 is Package.swift's `.macOS(.v14)`; keep the two in step.
SWIFT_SDK_FLAGS=(-Xlinker -platform_version -Xlinker macos -Xlinker 14.0
                 -Xlinker "$(xcrun --sdk macosx --show-sdk-version)")
swift() {
  if [ "${1:-}" = build ]; then shift; command swift build "${SWIFT_SDK_FLAGS[@]}" "$@"
  else command swift "$@"; fi
}
