#!/bin/bash
# preview-liquid-glass 實作與驗證用指令。在 worktree 任何位置執行：
#   beat/changes/preview-liquid-glass/dev.sh check    編譯並執行 App/scripts/liquid-glass-mockup-check*.swift
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
unset LMUX_CONTROL_SOCKET LMUX_PANE_ID LMUX_PANE_NONCE LMUX_PANE_TOKEN LMUX_SOCKET
export PATH="/usr/bin:$PATH"
OUT="${TMPDIR:-/tmp}/preview-liquid-glass"
mkdir -p "$OUT"

case "${1:-}" in
  check)
    swiftc -parse-as-library -o "$OUT/liquid-glass-app-check" \
      App/Sources/LmuxTokens/Tokens.swift \
      App/Sources/LmuxUI/PreviewTarget.swift \
      App/Sources/LmuxUI/MarkdownHTML.swift \
      App/scripts/liquid-glass-app-check.swift \
      && "$OUT/liquid-glass-app-check" \
      && swiftc -parse-as-library -o "$OUT/liquid-glass-mockup-check" \
        App/scripts/liquid-glass-mockup-check*.swift \
      && "$OUT/liquid-glass-mockup-check" ;;
  *)
    sed -n 2,3p "$0"; exit 2 ;;
esac
