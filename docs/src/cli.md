# The lmux CLI

lmux, a macOS terminal for Claude Code and Codex, ships a small command line tool, `lmux`, for scripts and agents. It's on the `PATH` in every lmux pane; the Homebrew cask also links it for other terminals ([Install](install.md)). It talks to the running lmux app over a local socket.

## `lmux list`

Lists workspaces and their panes: ids, titles, folders, each pane's agent state (`idle`, `running`, `needs input`, `done`, `failed`) and agent (`claude`, `codex`, or [another agent's name](any-agent.md)). `--json` also has each pane's `session` and `workspaceTitle`. The selected workspace is marked with `*`. Each tab is listed as its own pane, with its position (`tab 2/3`) and `*` on the visible one. In JSON: `tab`, `tabs` and `tabShown`.

```sh
lmux list
lmux list --json   # the same, as JSON
```

## `lmux send`

Types text into a pane. `\n` presses Return (`\t` and `\\` work too).

```sh
lmux send "npm test\n"            # into this pane
lmux send --pane <id> "y\n"       # into a pane by id (lmux list shows them)
```

Without `--pane`, it's the pane it runs in (`$LMUX_PANE_ID`). From inside a pane, `send` may only target that same pane, so an agent can't type into the wrong one by mistake. To lift that:

```sh
defaults write dev.lmux.app allowCrossPaneSend -bool true
```

## `lmux new-workspace`

Opens a workspace and prints its id and its pane's id.

```sh
lmux new-workspace                         # in your home folder (or Ghostty's working-directory)
lmux new-workspace --cwd ~/code/app        # in that folder
lmux new-workspace --cwd . --cmd "claude"  # and run a command in it
lmux new-workspace --background --cmd "codex"  # without switching to it
```

## `lmux new-tab`

Opens a tab and prints the workspace id and the new tab's id. `lmux send --pane` takes that id.

```sh
lmux new-tab                                  # after this tab, or in the focused pane from outside lmux
lmux new-tab --pane <id> --cmd "npm test"     # in that pane, running a command
lmux new-tab --background                     # behind the current tab, without switching to it
```

## `lmux notify`

Posts a notification, attributed to the pane it runs in. At most one per pane every 5 seconds; a burst becomes one, with the latest text.

```sh
lmux notify --title "Build" "done in 42 s"
```

## `lmux wait`

Blocks until a pane's agent (or a workspace, as its row shows it) gets somewhere, then prints its state and, for a done turn, its last reply (otherwise what the row says: the question asked, the error).

```sh
lmux wait <id>                          # until it's no longer running
lmux wait <id> --until done --timeout 1800 --json
```

- `--until`: `done` (done or failed), `needs-you`, `idle`, or `any` (the next change). By default, anything but running.
- Only a state reached after the last input lmux typed there with a Return (`lmux send "…\n"`, `new-workspace --cmd`) counts, so `send` then `wait` never returns the previous turn. If that input starts nothing, the state never changes: always pass `--timeout`.
- `--json` gives `state`, `pane`, `workspace`, `agent`, `session`, `reply` and `detail`.
- Exit 0 when it got there, 1 on timeout, 2 when the pane or workspace is gone (or lmux quit), 3 on other errors (lmux not running or not answering too).
- The CLI just waits on lmux's socket: nothing polls, in the CLI or in the app.

An agent starting another one: `lmux new-workspace --background --cwd . --cmd "codex 'Review the diff. Write your findings to .review.md.'"`, then `lmux wait <pane> --until done --timeout 1800 && cat .review.md`. `--background` adds the workspace's row without switching your screen to it. [Worked example](https://github.com/sooftware/lmux/blob/main/docs/agents.md#worked-example-claude-asks-codex-for-a-review).

## From outside lmux

From another terminal, Raycast or Hammerspoon, `lmux list` and `lmux notify` just work. `lmux send`, `lmux new-workspace --cmd` and `lmux new-tab --cmd` type into a shell, so they're refused from outside lmux unless you turn on **Settings → General → Allow other apps to send input to lmux** (the same as `defaults write dev.lmux.app allowExternalSend -bool true`). Leave it off unless you need it.

Outside lmux the CLI finds the app's socket in `~/Library/Application Support/lmux/control.sock` (or `$LMUX_CONTROL_SOCKET`). It only talks to lmux running as the same user.

These rules guard against mistakes, like an agent typing into the wrong pane. They aren't a security boundary.
