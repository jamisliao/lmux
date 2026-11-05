# lmux for agents

An agent running in an lmux pane can open workspaces, start other agents in them, wait for them
to finish and read what they said, with the bundled `lmux` command (on `PATH` in every pane).
Any agent can also show its status in the sidebar with one escape sequence.

For Claude Code there's a ready-made skill: copy [`skills/lmux`](../skills/lmux) to
`~/.claude/skills/lmux`, and Claude uses `lmux` when you ask it to hand work to another agent.

## The commands

```sh
lmux new-workspace [--cwd DIR] [--cmd CMD] [--background]
                                              # prints: workspace <id> pane <id>
lmux new-tab [--pane ID] [--cmd CMD] [--background]
                                              # a tab in that pane (default: yours); prints the same
lmux send [--pane ID] TEXT                    # types TEXT ("\n" presses Return)
lmux list [--json]                            # every workspace and pane, with its agent and state
lmux wait ID [--until S] [--timeout SECS] [--json]
lmux notify [--title T] TEXT                  # a notification from your pane
```

Ids are the full ids `lmux list` and `new-workspace` print. Inside a pane, `$LMUX_PANE_ID` is your own.
`--background` adds the workspace's row without switching to it, so the user's screen and focus
stay where they are; use it whenever an agent starts one.

**Who may type where.** `new-workspace --cmd` works from inside any pane. `lmux send` from inside a
pane only types into that same pane, unless the user turned on
`defaults write dev.lmux.app allowCrossPaneSend -bool true`. So to give another agent its task,
put it in the command that starts it (`--cmd "codex '…'"`), not in a later `send`.

### `lmux list --json`

An array of workspaces (`id`, `title`, `selected`, `panes`). Each pane:

| key | |
|---|---|
| `id` | the pane id |
| `title` | the pane's title (the session title, else the terminal title, else the folder) |
| `cwd` | its directory |
| `state` | `idle`, `running`, `needs input`, `done` or `failed` |
| `agent` | `claude`, `codex`, the `app=` of a program that reports itself (below), or `""` |
| `session` | the Claude Code or Codex session id, or `""` |
| `workspaceTitle` | the title of its workspace's row |
| `focused`, `claude` | the focused pane of its workspace; a Claude Code or Codex session runs there |

### `lmux wait`

Blocks until a pane (or a whole workspace, as its sidebar row shows it) gets to a state, then
prints it. The CLI sleeps on lmux's socket; nothing polls, in the CLI or in the app.

| `--until` | ends when the state is |
|---|---|
| (none) | anything but running: done, failed, needs input or idle |
| `done` | done or failed (the turn ended) |
| `needs-you` | needs input |
| `idle` | idle |
| `any` | different from what it was when the wait began |

Only a state that came **after** the last input lmux typed into the target with a Return
(`lmux send "…\n"`, or the `--cmd` of `new-workspace`) counts, so `send` (or `new-workspace --cmd`)
followed by `wait` never returns the previous turn's done. Without `--until any`, a target that is
already there answers at once. If that input starts nothing (a plain shell, an agent that ignores
it), the state never changes and the wait never ends: always pass `--timeout`.

`wait` is for the `lmux` CLI: it keeps its connection open until the answer, and a client that
closes its side early (`nc -N`, `socat`) has its wait dropped.

Output: the state on the first line, then the reply of a done turn (or what the row says: the
question asked, the error). `--json` gives `state`, `pane`, `workspace`, `agent`, `session`,
`reply` (the whole last reply, when the agent's hooks said it) and `detail` (the row's line 2).

| exit | |
|---|---|
| 0 | got there |
| 1 | `--timeout` passed first |
| 2 | the pane or workspace is gone (closed, never existed, or lmux quit) |
| 3 | anything else (bad arguments, lmux not running or not answering) |

### Worked example: Claude asks Codex for a review

Claude Code, in a pane, opens a workspace in the same folder (in the background: the user keeps
looking at Claude) with Codex reviewing the diff, waits for it, and reads the result:

```sh
out=$(lmux new-workspace --background --cwd "$PWD" \
  --cmd "codex 'Review the uncommitted changes. Write your findings to .review.md, most important first.'")
pane=${out##* }                                   # "workspace <id> pane <id>" -> the pane id

lmux wait "$pane" --until done --timeout 1800     # blocks until Codex's turn ends
case $? in
  0) cat .review.md ;;                            # Codex's findings
  1) echo "Codex is still at it; look at its workspace" ;;
  2) echo "the review workspace was closed" ;;
esac
```

If Codex stops to ask for an approval instead, a plain `lmux wait "$pane"` returns `needs input`
(the user answers it in that pane; `lmux send` from Claude's pane can't). For a short answer,
`lmux wait "$pane" --until done --json` has Codex's last reply in `.reply` when its hooks are
installed; a file, as above, is the sure way to get a long one.

## Any agent: OSC 7501

Claude Code reports through its hooks and Codex prints its own status. Any other program can do
what Codex does: print an OSC 7501 report, and its pane shows it like Codex's, with a ring, a badge and one
notification per wait:

```sh
printf '\e]7501;state=blocked:app=my-agent\e\\'
```

| `state=` | the pane shows |
|---|---|
| `working` | running |
| `blocked` (`kind=permission`, `question` or `auth`) | needs you: "my-agent needs you", "my-agent has a question", "my-agent needs you to sign in" |
| `done` | done ✓ (the `idle` after it keeps it done) |
| `error` | failed |
| `idle` | idle (while running or waiting: you stopped it) |
| `clear` | nothing: it left (with or without `app=`) |

A few rules keep it honest:

- **`app=` names the program.** It's the agent's name in `lmux list`, `lmux wait --json` and the
  pane header (at most 15 characters arrive). Reports without one are ignored.
- **Only from that program.** Anything can print the escape, a file shown with `cat` too, so a
  report (`clear` included) counts only while the pane's foreground program *is* the one `app=`
  names: its executable, or the script a shell or interpreter runs (`./my-agent`,
  `node …/bin/my-agent`, `python3 -m my-agent`; `my-agent.py` counts as `my-agent`). Another
  program's argument never names it (`sort notes` isn't `notes`), and programs that show other
  bytes or run other programs (`cat`, `less`, `tail`, `sort`, `curl`, `ssh`, `docker`,
  `kubectl`, `xargs`, `sudo`, task runners like `npm`, `make` or `cargo`, …) never count. That list is best effort, not every program that
  can print a file. So the `printf` above, typed at a shell prompt, does nothing: it has to come
  from `my-agent`. One exception: the last report your program printed just before it quit
  still counts, once, if it ends the turn (`done`, `error`, `idle` or `clear`) and the shell has
  the terminal back. A program stopped with `⌃Z` hasn't quit.
- **One alert per ask.** The same report again changes nothing. After an answer (Return in the
  pane, or `lmux send` with a newline), the next `blocked` is a new ask and alerts again (no
  `working` needed in between). Arrow keys in a menu aren't an answer.
- **Hooks win.** A pane where hooks bound a Claude Code (or Codex) session ignores these
  reports, so an agent that does both never notifies twice.
- **Status only.** No session: no resume on restart, History, rewind or edit. A program that
  quits without `clear` keeps a done or failed row; a running or waiting one goes back to idle
  as soon as it exits.

The protocol, with `id`, `progress`, `msg` and the rest (lmux reads `state`, `kind` and `app`), is
[OSC 7501](https://www.superlogical.com/rex/docs/build/program-status).
