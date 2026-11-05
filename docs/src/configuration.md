# Configuration

lmux is a macOS terminal on libghostty, and it's configured the way Ghostty is: one plain-text file in Ghostty's syntax. It reads your Ghostty config as it is, and its own Settings window covers the rest, about ten settings in all.

## Your Ghostty config

lmux reads the files Ghostty reads on macOS, in this order:

1. `~/.config/ghostty/config` (or `$XDG_CONFIG_HOME/ghostty/config`), and `config.ghostty` next to it
2. `~/Library/Application Support/com.mitchellh.ghostty/config`, and `config.ghostty` next to it
3. `~/.config/lmux/config`, which lmux's Settings writes. It's loaded last, so a key set here wins.

Themes, fonts, `keybind`, colors, padding and the rest of Ghostty's options work as they do in Ghostty ([reference](https://ghostty.org/docs/config/reference)). Settings applies a change to every pane at once.

Where your config says nothing, lmux's defaults are:

```
theme = light:Nord Light,dark:Nord
window-padding-x = 14
window-padding-y = 10
minimum-contrast = 2
unfocused-split-opacity = 1
```

`minimum-contrast = 2` draws text black or white where a theme pair would make it unreadable (Claude Code's dark theme on a light terminal, say).

The font is Ghostty's default (JetBrains Mono), or D2Coding on a Mac whose system language is Korean. Hangul always renders in D2Coding at exactly two cells unless you map it yourself (see [Korean input](korean-input.md)).

## Where new workspaces and splits start

| key | what lmux does |
|---|---|
| `working-directory` | A new workspace starts here: an absolute path or `~/…` that exists. `home`, unset or anything else: your home folder. |
| `working-directory = inherit` | A new workspace starts in the focused pane's folder. |
| `window-inherit-working-directory = true` | The same, set explicitly. (`tab-inherit-working-directory = true` works too.) |
| `split-inherit-working-directory = false` | A split starts in `working-directory` instead of its pane's folder. |

Ghostty's own default for the inherit keys is true; lmux's, when they're unset, is home. lmux reads these four keys from the files above itself and doesn't follow `config-file` includes for them. A relaunch, History and the cmux import always use each session's own saved folder.

## Settings

`⌘,` opens Settings. Theme, font and size go into `~/.config/lmux/config` (other lines and comments there are kept as you left them); the rest are lmux's own and live in `~/Library/Application Support/lmux/settings.plist`.

| tab | setting | default |
|---|---|---|
| Appearance | Appearance: System, Light or Dark | System |
| Appearance | Theme for light mode and for dark mode, from a gallery of 26 (Catppuccin, Tokyo Night, Gruvbox, Solarized, Dracula and more) | Nord Light / Nord |
| Appearance | Sidebar matches the terminal background | off |
| Appearance | Tab bar on panes with one tab (off: shown only once a pane has two tabs) | on |
| Font | Family, size and fallbacks (for glyphs the font lacks, such as Nerd Font icons) | JetBrains Mono, or D2Coding on Korean systems |
| Notifications | Sound | Off |
| Notifications | Unread count on the Dock icon | off |
| Notifications | Ring around a pane that needs you | on |
| Notifications | Remind me after (a done or waiting row you haven't looked at breathes) | 3 minutes |
| Notifications | Remind again via notification | off |
| General | Ask before quitting while something runs | on |
| General | Restore terminal output after relaunch | on |
| General | Allow other apps to send input to lmux | off |

General also has the Claude Code and Codex hooks (install, update, uninstall), **Import from cmux…** and **Open config file**.

**Allow other apps to send input to lmux** lets scripts like Raycast or Hammerspoon use `lmux send` and `lmux new-workspace --cmd` from outside lmux. It's stored as `defaults write dev.lmux.app allowExternalSend -bool true`. Leave it off unless you need it; from inside a pane those commands always work. See [The lmux CLI](cli.md).

## An example `~/.config/lmux/config`

```
# Loaded after ~/.config/ghostty/config, so a key set here wins.
theme = light:Nord Light,dark:Nord
font-family = D2Coding
font-family = Symbols Nerd Font Mono
font-size = 13
```

A second `font-family` line is a fallback, tried for glyphs the first one lacks.
