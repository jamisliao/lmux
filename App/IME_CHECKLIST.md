# Korean IME manual checklist

Run by hand with the real macOS Korean input source before each release.
Automation (`scripts/imetest.sh`) covers the NSTextInputClient call sequences,
pty bytes, preedit position and glyph widths, but it cannot press physical keys,
see the candidate/caret UI, or use a real Claude Code session.

**Automated on CI** (`.github/workflows/ci.yml`, job `app`: the runner enables 2-Set Korean and runs
`imetest.sh --visible`, so these run against the REAL macOS IME, at the shell-like pty sink):
#1 fast typing, #2 Enter, #3 Shift+Enter (bytes), #4/#5 Backspace, #6 preedit at the cursor,
#7 Space commit without a duplicate, #8 Cmd+C / Cmd+V, #9 Cmd+V while composing, #10 Cmd+T,
#11 Esc (bytes, not vim itself), #12 Left exactly once, #13 `.`, #14 mid-word switch (switched
programmatically, not with the switch key), #15 2-cell width and baseline, #18 Nord / Nord Light.

**Shortcuts** (`lmux-imetest/Shortcuts.swift`): every menu key, Ghostty binding, Control key and
⇧ / ⌥ letter, in legacy mode and kitty 1 / 5 / 31, idle and right after composing 가: the action
happens and no jamo or stray text reaches the pty. Headless with the simulated IME on every run;
`imetest.sh --visible --probe` (about 3 minutes, shows a window and switches the input source) runs
the same table against the REAL IME, plus a focus change while composing and dead keys (ABC).

**Still manual**: everything inside a real `claude` input box (#2/#3 visual result, Shift+Enter
line break), #11 inside `vim`, #14 with the physical Caps Lock / Ctrl+Space key, #16 key repeat,
#17 dictation / emoji picker, and the caret / candidate UI by eye.

Setup: System Settings > Keyboard > Input Sources: **2-Set Korean (두벌식)**.
Launch `App/build/lmux.app`. Run each case at the shell prompt and again inside
`claude` (Claude Code input box). Pass = exactly what is written, no stray jamo,
no doubled or missing syllables.

| # | Do this | Expected |
|---|---|---|
| 1 | Type `안녕하세요 반갑습니다` as fast as you can | Every syllable appears once, in order |
| 2 | Type `안녕` and press **Enter** without a space | `안녕` is submitted on the same line; nothing left on the next prompt; one Enter is enough |
| 3 | Type `안녕` and press **Shift+Enter** (inside `claude`) | New line in the input box; `녕` stays on the first line, not moved or duplicated |
| 4 | Type `한`, press Backspace 3 times | `한 → 하 → ㅎ → (nothing)`; the character before `한` is untouched |
| 5 | Press Backspace once more | Deletes the previous character normally |
| 6 | While composing (`가` underlined), look at the caret | The underlined syllable sits exactly at the cursor; no ghost copy elsewhere |
| 7 | Type `가` and press Space | `가 `, the composing underline disappears, no second `가` drawn |
| 8 | Select text with the mouse, press **Cmd+C**, then **Cmd+V** (Korean source active) | Copy and paste work |
| 9 | Type `가` then **Cmd+V** | `가` followed by the pasted text |
| 10 | Type `가` then **Cmd+T** | `가` is committed; the new-tab action fires (spike: no-op/log only) |
| 11 | Type `가` then **Esc** (try in `vim` insert mode) | `가` stays, vim leaves insert mode with one Esc |
| 12 | Type `가` then **←** (Left arrow) | `가` committed, cursor moves one cell left (exactly one, not two) |
| 13 | Type `가` then `.` | `가.` |
| 14 | Toggle input source (Caps Lock / Ctrl+Space) mid-word: `가` → ABC → `a` | `가a`; the switch key itself sends nothing |
| 15 | Mixed line `한글abc한글` then move the cursor across it | Hangul is 2 cells wide, baseline lines up with Latin, no overlap |
| 16 | Hold a jamo key (key repeat) | Repeats predictably, no freeze |
| 17 | Dictation / emoji picker (Ctrl+Cmd+Space) insert | Inserted once at the cursor |
| 18 | Switch macOS to Dark / Light appearance | Terminal follows Nord / Nord Light, titlebar blends |

Known-risk item: **#12**. Upstream Ghostty deliberately does *not* replay a plain
Left arrow after a Korean commit ("AppKit already leaves the caret in place").
lmux replays any key the IME passes on (doCommand), which is what the real
2-Set IME did in the recorded traces on macOS 26. If the cursor moves two cells,
report it.
