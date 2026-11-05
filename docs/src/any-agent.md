# Any agent (OSC 7501)

Any CLI runs in lmux, a light macOS terminal on libghostty. Status, rewind, resume and History are built for Claude Code and Codex. This page is about the one piece another agent can plug into: reporting its own state, the way Codex does.

## What OSC 7501 is

OSC 7501 is an escape sequence a terminal program prints to say what it's doing: working, waiting for the user, done. Codex's terminal UI prints it in its own pane, and that's where lmux's Codex status comes from ([Codex](codex.md#status-from-codex-itself)). lmux only takes it from the pane's foreground program, so a report can't come from a file shown with `cat` or from another program.

## Reporting your state

Any program reports its state with one line. lmux shows it on the row and the pane, with the same ring, badge, `⇧⌘J` and one notification per wait as Claude Code and Codex, and its name in `lmux list`:

```sh
printf '\033]7501;state=working:app=my-agent\033\\'
```

- `state` is `working`, `blocked`, `done`, `idle`, `error` or `clear` (the program stopped reporting).
- `blocked` takes a kind: `state=blocked:kind=permission:app=my-agent` (or `kind=question`, `kind=auth`). The row says "my-agent needs you", "my-agent has a question" or "my-agent needs you to sign in".
- `app` names the program, up to 15 bytes. A report counts only while the pane's foreground program is the one it names: its executable, or the script a shell or interpreter runs (`./my-agent`, `node …/bin/my-agent`, `python3 -m my-agent`). Another program's argument never names it (`sort notes` isn't `notes`), and programs that show other bytes or run other programs (`cat`, `less`, `sort`, `curl`, `ssh`, `docker`, `xargs`, `sudo`, task runners like `npm` or `make`…) never count. That list is best effort. So the line above does nothing typed at a prompt: `my-agent` has to print it. The last report a program prints just before it quits still counts, once, if it ends the turn (`done`, `error`, `idle`, `clear`) and the shell has the terminal back.
- The same report again changes nothing. After an answer (Return, or `lmux send` with a newline), the next `blocked` is a new ask and notifies again. Arrow keys in a menu aren't an answer.
- Hooks win: a pane where Claude Code's (or Codex's) hooks bound a session ignores these reports, so nothing notifies twice.
- It's status only: no resume, History or rewind. A program that quits without `clear` keeps a done or failed row; a running or waiting one goes back to idle as soon as it exits.

Another agent can then wait for yours with [`lmux wait`](cli.md#lmux-wait).

## Hooks

If your agent has hooks of its own, or you'd like status, resume or History for it, [open an issue](https://github.com/sooftware/lmux/issues) and say which agent and how it reports its state.

## Without any of it

An agent with no reporting still gets everything that isn't agent-specific: workspaces, splits, restore after a relaunch (as a shell in the same folder), and the [`lmux` CLI](cli.md), including `lmux notify` to post a notification from a script or a hook.
