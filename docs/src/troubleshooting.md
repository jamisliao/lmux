# Troubleshooting

<!-- description: Fixes for the few things that go wrong: Claude's dark prompt band, a sidebar that never updates, Codex hooks, macOS permission prompts, CLI errors. -->

Fixes for the few things that go wrong in lmux, the macOS terminal for Claude Code and Codex.

## Why is Claude's prompt a dark band on a light theme?

Claude Code's own theme defaults to dark, so it paints its prompt row dark whatever your terminal looks like. Run `/theme` in Claude and pick Auto. It then follows lmux's colors, light or dark.

## The sidebar never updates for a `claude`

Usually the hooks aren't where that `claude` looks for them. If you export `CLAUDE_CONFIG_DIR` in your shell rc and open lmux from the Dock, lmux installs the hooks into `~/.claude/settings.json` while `claude` reads another folder.

lmux notices. If a `claude` has run in a pane for about ten seconds and no hook has arrived from it, the pane gets one calm card ("lmux isn't receiving Claude Code hooks from this pane") with the likely reason and a button:

- the hooks aren't installed: **Install Hooks…**
- they're in `~/.claude` while this `claude` uses another `CLAUDE_CONFIG_DIR`: **Install There…** or **Choose Folder…**
- this `claude` started before you installed them: restart it

Once a hook arrives from a pane, it never asks again.

A `claude` inside `script`, tmux or screen in a pane shows no state at all, because lmux can't tell it's the pane's own. Run it directly in the pane.

## Codex shows no status, or isn't remembered for resume

- Codex runs new hooks only after you trust them. The next time it starts, choose **Trust all and continue** at "Hooks need review". Settings → General says whether they're installed and trusted.
- Status comes from Codex itself while `codex` is the pane's foreground program; inside ssh or tmux it only comes through hooks.
- A Codex background server started outside lmux sends no hooks: status works, but the session isn't remembered for resume. lmux says so in the pane, once.

## A row is stuck on "needs you" or "running"

If a hook got missed, right-click the row and choose **Clear Status** (it works on a multi-selection too). It resets the badge and ring to idle without touching the agent, and the next hook updates it normally.

## Why does macOS ask lmux for permissions?

Programs you start in a terminal borrow its identity for macOS privacy prompts (Accessibility, Automation, Contacts, Full Disk Access…), so when a script or app you launch from lmux wants one, macOS asks about lmux. That's macOS, and Terminal, iTerm2 and Ghostty work the same way. lmux needs none of these for its own features, so grant only what the program you're running needs, or start that program outside the terminal.

## macOS keeps asking even though lmux is already allowed

macOS remembers a permission together with the app's signature. If an older lmux with a different signature (a build from source, say) was allowed, System Settings still shows lmux as on, but the lmux you run now doesn't match it, so macOS asks again. Reset that entry once and allow it at the next prompt:

```sh
tccutil reset Accessibility dev.lmux.app   # or ScreenCapture, AppleEvents…
```

The same goes for Screen Recording: after switching from a dev build, lmux can keep asking for it although it's on in System Settings. Reset it and allow it once:

```sh
tccutil reset ScreenCapture dev.lmux.app
```

## `lmux send` says it's refused

From inside a pane, `lmux send` may only type into that same pane. From outside lmux (another terminal, Raycast), `send` and `new-workspace --cmd` need **Settings → General → Allow other apps to send input to lmux**. See [The lmux CLI](cli.md).

## "lmux is not running"

The CLI talks to the running app. Open lmux, or if you run it with a custom `LMUX_STATE_DIR`, set the same one (or `LMUX_CONTROL_SOCKET`) for the CLI.

## A setting or the layout came back empty

If a state file is ever unreadable, lmux keeps it aside as `<name>.bad-<time>` in `~/Library/Application Support/lmux/` and starts that part fresh, instead of writing over it. The old file is still there to look at.

## Still stuck?

[Open an issue](https://github.com/sooftware/lmux/issues) with what you did, what you expected, and your macOS and lmux versions. **Help → Report an Issue…** in lmux opens the same page.
