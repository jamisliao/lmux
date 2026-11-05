# Install

lmux, a light terminal for Claude Code and Codex, runs on macOS 14 (Sonoma) or later, on Apple silicon. It's one app, with the `lmux` command line tool inside it.

## Homebrew

```sh
brew install --cask sooftware/tap/lmux
```

The cask puts lmux.app in Applications and links the `lmux` command onto your `PATH`. Inside an lmux pane, `lmux` is always on the `PATH` anyway.

## Download

Download [lmux-arm64.dmg](https://github.com/sooftware/lmux/releases/latest/download/lmux-arm64.dmg), open it and drag lmux.app to Applications. The zip and older versions are on [GitHub Releases](https://github.com/sooftware/lmux/releases).

To use `lmux` from other terminals too, link it into any folder on your `PATH`, for example:

```sh
ln -s /Applications/lmux.app/Contents/Resources/bin/lmux ~/.local/bin/lmux
```

## Build from source

`scripts/bootstrap.sh` fetches the pinned Ghostty and Zig and builds the terminal framework, then `App/scripts/bundle.sh` builds `App/build/lmux.app`. The details, and the test harnesses, are in [App/README.md](https://github.com/sooftware/lmux/blob/main/App/README.md) and [CONTRIBUTING.md](https://github.com/sooftware/lmux/blob/main/CONTRIBUTING.md).

## Updating

lmux never checks for updates itself (it makes no network calls at all). Homebrew does:

```sh
brew upgrade --cask lmux
```

With a download, replace lmux.app with the new one. Either way, quitting for the update loses nothing: lmux reopens the same workspaces, splits and folders, and every Claude Code or Codex session resumes where it was (see [Workspaces & panes](workspaces.md#after-a-relaunch)).

## Uninstalling cleanly

lmux adds a few hooks to your agents' settings. Take those out first, while lmux is still there:

1. In lmux, choose **lmux → Uninstall Claude Code Hooks…**, and **Uninstall Codex Hooks…** if you installed those. If you haven't edited the file since, it goes back byte for byte; if you have, only lmux's lines come out.
2. Quit lmux and delete the app:

   ```sh
   brew uninstall --zap --cask lmux   # also deletes the state dir and lmux's preferences
   ```

   With a download, drag lmux.app to the Trash.
3. Delete what's left:

   ```sh
   rm -rf ~/Library/Application\ Support/lmux ~/.config/lmux
   defaults delete dev.lmux.app 2>/dev/null
   ```

That's everything lmux writes. The full list, file by file, is in [Privacy & files on disk](privacy.md).
