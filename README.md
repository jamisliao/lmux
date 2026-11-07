<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.svg">
    <img src="assets/logo.svg" alt="lmux" width="240">
  </picture>
</p>

<h3 align="center">light mux.</h3>

<p align="center">
  A light, native macOS terminal for living in Claude Code and Codex all day.
</p>

<p align="center">
  <a href="https://github.com/sooftware/lmux/releases/latest/download/lmux-arm64.dmg">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="assets/download-macos-dark.svg">
      <img src="assets/download-macos.svg" alt="Download app for macOS" width="146" height="60">
    </picture>
  </a>
</p>

<p align="center">
  English | <a href="README.ko.md">한국어</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ja.md">日本語</a> | <a href="README.es.md">Español</a> | <a href="README.de.md">Deutsch</a> | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.ru.md">Русский</a> | <a href="README.tr.md">Türkçe</a> | <a href="README.vi.md">Tiếng Việt</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-2E3440?logo=apple&logoColor=white" alt="macOS 14+">
  <img src="https://img.shields.io/badge/built%20on-libghostty-5E81AC" alt="built on libghostty">
  <a href="https://github.com/sooftware/lmux/releases/latest"><img src="https://img.shields.io/github/v/release/sooftware/lmux?label=release&color=88C0D0" alt="latest release"></a>
  <img src="https://img.shields.io/badge/license-MIT-A3BE8C" alt="MIT">
</p>

<p align="center">
  <code>brew install --cask sooftware/tap/lmux</code> · macOS 14+, Apple silicon
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/hero/hero-dark.webp">
    <img src="assets/hero/hero-light.webp" alt="lmux: five workspaces in the sidebar, each in a different state (working, done, needs input, failed, waiting for you); a prompt typed into a split where Claude Code and Codex work side by side" width="900">
  </picture>
</p>

---

The other day I was working in the terminal and caught myself wondering:

*When did terminals get this heavy? And do they really need to be?*

Terminal apps these days ship with a browser, SSH workspaces, even PR badges. With that much built in, of course they're heavy. AI has changed a lot about how I work, but to me a terminal is still just text in, text out. Personally, I don't browse the web or open SSH workspaces in it. I'm also a defaults person: I barely touch the settings. The only real difference is that I used to keep one terminal open, and now I'm talking to several agents across a bunch of sessions at once. Meanwhile my terminal kept getting heavier with features I never touched, and the little annoyances added up. So I built **lmux**: just the parts I actually use, plus a few things I'd always wanted.

## Highlights

- **Light.**<br>
  A 25 MB app that idles near 0% CPU, whether you have one workspace open or twenty. It's native Swift on libghostty. No Electron, no browser engine, and about ten settings.

- **Quit, update, reboot. It all comes back.**<br>
  Same workspaces, splits and folders, and every Claude Code or Codex session resumes where it left off. Closed one last week? History (`⇧⌘H`) finds it and brings it back.

- **Know which agent needs you.**<br>
  Status comes straight from Claude Code's hooks and from Codex itself: running, needs you, done or failed. You get a ring on the pane, a badge on the row and one notification per event, and `⇧⌘J` jumps to whoever is waiting. Any other agent can join with one escape sequence. lmux never wraps `claude` or `codex`; it only listens.

- **Take back a prompt.**<br>
  You hit Enter, see which pane it went to, and think, "oh, fuck." Hover the turn and press `×`, and Claude rewinds to just before it, without restarting, like it never happened. `✎` does the same but hands you the prompt back to fix and resend. (Claude Code only.)

  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/gifs/forget-x-dark.webp">
    <img src="assets/gifs/forget-x-light.webp" alt="Pressing × on a prompt sent by mistake: the prompt and Claude's reply disappear" width="700">
  </picture>

- **Bring your cmux setup.**<br>
  One click brings over your theme, fonts, shortcuts and even your open workspaces and splits, with their Claude and Codex sessions resumed. It works like a new browser importing your bookmarks from Chrome. If you change your mind, Undo Import puts it all back.

- **Korean input that just works.**<br>
  I'm a Korean developer, so this one's personal. No dropped or mangled syllables while you type, and Hangul takes up exactly two cells. Japanese and Chinese (Pinyin, Zhuyin) [got the same treatment](https://lmux.dev/docs/korean-input/#chinese-and-japanese-input): the caret shows inside the text you're composing, arrow keys stay with the IME, and `⌃C` is still Ctrl+C. [한국어로 보기 →](https://lmux.dev/docs/ko/)

It also has tabs in every pane, session titles from Claude Code, 26 themes and copy-as-markdown. See **[all features](docs/features.md)** for the rest.

## Installation

### Download

<a href="https://github.com/sooftware/lmux/releases/latest/download/lmux-arm64.dmg">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/download-macos-dark.svg">
    <img src="assets/download-macos.svg" alt="Download app for macOS" width="146" height="60">
  </picture>
</a>

Open the .dmg and drag lmux.app to Applications. The zip and older versions are on [GitHub Releases](https://github.com/sooftware/lmux/releases).

### Homebrew

```sh
brew install --cask sooftware/tap/lmux
```

macOS 14+ on Apple silicon. To build from source, see [App/README.md](App/README.md).

Docs: [lmux.dev/docs](https://lmux.dev/docs/)

## Usage

**First launch.** If you're coming from cmux, lmux offers to bring over your setup and your open workspaces. Then it offers to install a few Claude Code hooks and shows you the exact diff to your `settings.json` before touching anything. Say yes to both, run `claude` in any pane, and the sidebar starts telling you which agent is running, which is done, and which one is waiting for you.

**Codex too.** If the Codex CLI is installed, lmux offers to install Codex hooks next, the same way (this time the diff is against `~/.codex/hooks.json`). Codex asks once to trust new hooks the next time it starts. Choose **Trust all and continue**.

**Every day.** These are the defaults; a `keybind` in your Ghostty config overrides them, and the menus show whatever is bound.

| to do this                                    | press                                            |
|-----------------------------------------------|--------------------------------------------------|
| new workspace                                 | `⌘N`                                             |
| split right / down                            | `⌘D` / `⇧⌘D`                                     |
| close a tab / a workspace                     | `⌘W` / `⇧⌘W`, or `×` on a hovered row            |
| new tab in the pane                           | `⌘T`                                             |
| switch tab                                    | `⇧⌘[` / `⇧⌘]`, `⌃1`–`⌃8`, `⌃9` for the last      |
| switch workspace                              | `⌘1`–`⌘8`, `⌘9` for the last, `⌃⌘[` / `⌃⌘]`     |
| reorder workspaces                            | drag a row                                       |
| move between panes                            | `⌘[` / `⌘]`                                      |
| zoom the focused pane (hide the rest)         | `⇧⌘↩`                                            |
| jump to the agent that needs you              | `⇧⌘J`                                            |
| latest unread / recent notifications          | `⇧⌘U` / click the bell                           |
| reset a row's status by hand                  | right-click it, then **Clear Status**            |
| search past sessions                          | `⇧⌘H`                                            |
| copy / edit & resend / remove a turn          | hover it, then `⧉` / `✎` / `×`                   |
| copy the last reply as markdown               | `⌥⌘C`                                            |
| undo the prompt you just sent                 | `⌘Z` while the "Sent to …" toast is up          |
| find in scrollback                            | `⌘F`                                             |
| toggle the sidebar                            | `⌃⌘S`                                            |
| theme, font and the rest                      | `⌘,`                                             |

Short GIFs of the agent ring, History, taking a turn back and Korean input are in [the tour](docs/tour.md).

## lmux vs cmux

Both apps on the same Mac, opened with 1, 10 and 20 workspaces (2 live shells each) and left idle. Lower is better. lmux lets go of its GPU memory when it's not the app you're looking at, so it's measured twice, in front and in the background behind another app. See the [methodology](scripts/BENCH.md).

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/bench-scaling-dark.svg">
    <img src="assets/bench-scaling.svg" alt="Memory and idle CPU at 1, 10 and 20 workspaces: lmux in front 182, 207 and 235 MB at 0.1% CPU; lmux in the background 45, 71 and 99 MB at 0.0% CPU; cmux 0.65.2 398, 548 and 661 MB at 7.2, 7.4 and 8.1% CPU" width="760">
  </picture>
</p>

|                          | cmux 0.65.2 | lmux, in front | lmux, in the background |
|--------------------------|------------:|---------------:|------------------------:|
| App size                 | 242 MB      | **25 MB**      | **25 MB**               |
| Memory, 1 workspace      | 398 MB      | **182 MB**     | **45 MB**               |
| Memory, 10 workspaces    | 548 MB      | **207 MB**     | **71 MB**               |
| Memory, 20 workspaces    | 661 MB      | **235 MB**     | **99 MB**               |
| Idle CPU, 1 workspace    | 7.16 %      | **0.07 %**     | **0.00 %**              |
| Idle CPU, 10 workspaces  | 7.39 %      | **0.12 %**     | **0.00 %**              |
| Idle CPU, 20 workspaces  | 8.10 %      | **0.10 %**     | **0.00 %**              |
| Settings                 | ~200        | **~10**        | **~10**                 |

<sub>M4 Pro, macOS 26.6.2, lmux 0.0.102 vs cmux 0.65.2. 2 panes per workspace, every shell live, 5 interleaved runs, medians. Memory is the physical footprint of all app processes; app size is the Apple-silicon `.app` on disk. The screen was locked during the run, so cmux was in the background too. Its memory moves a lot with window state, so treat its numbers as a single snapshot. The shells and agents inside the panes are the same on both sides and aren't counted; this is the terminal's own cost. lmux's 0.07–0.12 % spread across workspace counts is within run-to-run noise.</sub>

Idle CPU is the number I care about most, because it's what drains your battery while twenty agents sit there waiting for you to read what they wrote.

**Why not lmux?**

- You use cmux's in-app browser, SSH workspaces, ports and PR widgets, custom commands, or more scripting than `lmux send` and `lmux new-workspace` give you.
- You need Linux or Windows.
- You want the knobs. cmux has about two hundred of them.

Then use cmux. It's great, and I'll keep learning from it.

## Contributing

Every change gets checked against these rules:

- **Light first.** A feature that mostly adds weight gets cut, even if it's nice to have. CI fails any PR that pushes idle CPU over budget.
- **Never wrap `claude`** (or `codex`). lmux listens through hooks and the files the agents already write, so they work exactly the same with or without it. Even `✎`, `×` and `⌘Z` don't edit a session: they drive Claude Code's own rewind menu in the running `claude`, so nothing restarts.
- **Calm UI.** You get one notification per event (plus an optional reminder) and one indicator per row, and nothing blinks unless something actually needs you.

Anything from typo fixes to whole modules is welcome, as long as it fits the rules above. See [CONTRIBUTING.md](CONTRIBUTING.md) for the build, the tests and the scope rule. For a new feature, open an issue first.

## FAQ

**Is this a cmux fork?**
> No. It's the same idea with a smaller scope, written from scratch and MIT licensed. There's no cmux code in this repo. Here's [how lmux and cmux differ](https://lmux.dev/docs/vs-cmux/).

**Why not Ghostty and tmux?**
> That's what I used before cmux, and it's a fine setup. But it can't give you a sidebar that knows which agent is waiting on you, a prompt you can take back, or Claude and Codex sessions that resume by themselves after a relaunch. lmux is basically libghostty plus those three things.

**Does it work with Codex?**
> Yes. The Codex CLI gets status, notifications, resume on restart, its own session titles, History and copy as markdown. Edit, remove and undo send are Claude Code only. Codex asks once to trust lmux's hooks ("Trust all and continue"); until you do, it runs without them.

**Other agents? Linux?**
> Any CLI runs in it. Resume, History and the hover actions are built for Claude Code and Codex, the two I live in, but any agent gets status and notifications by reporting its state the way Codex does, with one escape sequence (OSC 7501): `printf '\e]7501;state=blocked:app=my-agent\e\\'`, printed by `my-agent` itself ([how](docs/agents.md#any-agent-osc-7501)). Linux and Windows, no. lmux is native AppKit on libghostty, and a port would be a different app.

**Does it phone home?**
> No. lmux makes no network calls at all. No telemetry, no crash reports, not even an update check (Homebrew does that). Everything it writes to disk, and how to remove it, is listed in [one paragraph on the features page](docs/features.md#what-does-lmux-write-to-disk-and-how-do-i-remove-it).

More questions: [FAQ](https://lmux.dev/docs/faq/)

## Acknowledgements

- [Ghostty](https://github.com/ghostty-org/ghostty) and libghostty, for doing the hard part
- [cmux](https://github.com/manaflow-ai/cmux), for the idea and the layout this borrows


<p align="center">
  If lmux ever let you take back a prompt you sent to the wrong pane, a star helps other people find the project.<br><br>
  <a href="https://github.com/sooftware/lmux"><img src="https://img.shields.io/github/stars/sooftware/lmux?style=social" alt="Star lmux on GitHub"></a>
</p>

<sub>MIT. Not affiliated with cmux, Ghostty, Anthropic or OpenAI; their names are used only to describe what lmux works with. Third-party licenses are in <a href="App/THIRD_PARTY_NOTICES.md">THIRD_PARTY_NOTICES</a>, also shipped inside lmux.app.</sub>
