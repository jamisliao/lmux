# Korean input

<!-- title: Korean input in a Mac terminal: Hangul IME and Ctrl+C fixes · lmux docs -->
<!-- description: What lmux fixes for Korean input: Enter, Backspace, Esc and shortcuts mid-syllable, and Hangul at exactly two cells in D2Coding. -->

I'm a Korean developer, so this one's personal. Upstream Ghostty drops or mangles Hangul in a few places while you're composing a syllable. lmux, a macOS terminal on libghostty, fixes them, so fast typing in a shell or in Claude Code arrives whole.

한국어로 쓴 자세한 설명은 [한국어 안내](ko.md)에 있어요.

## What's fixed

- **Enter mid-syllable.** Press Return while the last syllable is still composing and the whole line arrives, last syllable included.
- **Shift+Enter, Esc, Backspace on the last jamo**, and `⌘T` or `⌘V` while composing: none of them eats or duplicates the syllable in progress.
- **The first syllable after a pause** composes properly (하이, not ㅎㅏ이), and the first jamo never commits on its own.
- **Shortcuts with the Korean input source on.** `⌃⌘S`, `⌥⌘C`, `⌘C` and the rest work without switching to English first: a `⌘` or `⌃` key the menus miss is retried as the key a Latin layout types there. `⌃C` reaches Claude Code as Ctrl+C, not a typed "ㅊ".

## How Hangul looks

Hangul renders in D2Coding at exactly two cells, whatever Latin font you use, so Korean text lines up with the grid. D2Coding ships inside lmux (you don't need to install it) and is the default font on a Mac whose system language is Korean.

To use another font for Hangul, map it yourself in your config with Ghostty's `font-codepoint-map`.

## History in Korean

History (`⇧⌘H`) searches past sessions in Korean too, with highlighted snippets. See [Claude Code](claude-code.md#history).

## Chinese and Japanese input

Pinyin, Zhuyin and Japanese (Romaji and Kana Typing) get the same tests as Korean. Each key is checked in a plain shell and in the keyboard modes Claude Code and Codex turn on, and the bytes have to match what the ABC layout sends.

- **Committing.** Space, a number key or Return commits the candidate once. The pinyin, bopomofo or romaji you typed never reaches the program, and neither does the digit, the tone key or the key itself. Return on unconverted pinyin types the letters. Return on a Japanese conversion or a Zhuyin buffer commits it without sending a newline, as in other Mac apps.
- **Editing.** Esc cancels the composition and Backspace edits it, and neither touches the line. In a Japanese conversion, Backspace deletes one character instead of the whole conversion. Full-width punctuation (，。、) arrives as typed.
- **Arrow keys.** While you're composing, they move through the composition or the candidates, and the caret is drawn where you are. When you're not, they move the cursor as usual.
- **Shortcuts.** `⌃C`, `⌘C`, `⌘V` and `⌘T` work as they do with ABC, idle or mid-composition. With Kana Typing or Zhuyin, `⌃C` reaches Claude Code as Ctrl+C, not Ctrl+そ or Ctrl+ㄏ.
- **The candidate window** opens at the cursor. In a longer conversion, it opens at the part being converted.
- **`font-thicken`** applies to the text you're composing as well as to committed text.

These checks run against a simulated input method. Some things still need checking with Apple's own Chinese and Japanese input methods: Shift switching between Chinese and English mid-word, `⌃C` and `⌘` keys mid-composition, and moving to another pane while composing.
