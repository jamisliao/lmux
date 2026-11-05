# FAQ

<!-- description: Is lmux a cmux alternative, why not Ghostty and tmux, does it work with Codex or without Claude Code, does it phone home, and more. -->

Questions people ask about lmux, a light, native macOS terminal for Claude Code and Codex built on libghostty.

## Is lmux a cmux alternative?

Yes, a lightweight one: the same idea with a smaller scope. It isn't a fork, though. lmux was written from scratch, it's MIT licensed, and there's no cmux code in it. Here's [how lmux and cmux differ](vs-cmux.md).

## Why not Ghostty and tmux?

That's what I used before cmux, and it's a fine setup. But it can't give you a sidebar that knows which agent is waiting on you, a prompt you can take back, or Claude and Codex sessions that resume by themselves after a relaunch. lmux is basically libghostty plus those three things. Your Ghostty config comes along as is ([Configuration](configuration.md)).

## Why not send PRs to cmux instead?

It's a scope thing. lmux is mostly about leaving things out, and you can't send that as a PR to a project that wants them in. I think cmux is right to want them; I just don't use them.

## Does it work without Claude Code?

Yes. Say no to the hooks and it's a plain Ghostty-based terminal with a sidebar and splits. Agent status and the hover actions only wake up when a `claude` (or `codex`) is running in a pane.

## Does it work with Codex?

Yes. The Codex CLI gets status, notifications, resume on restart, its own session titles, History and copy as markdown. Edit, remove and undo send are Claude Code only. Codex asks once to trust lmux's hooks ("Trust all and continue"); until you do, it runs without them. See [Codex](codex.md).

## Other agents? Linux?

Any CLI runs in it. Resume, History and the hover actions are built for Claude Code and Codex, the two I live in, but any agent gets status and notifications by reporting its state the way Codex does, with one escape sequence (OSC 7501): `printf '\e]7501;state=blocked:app=my-agent\e\\'`, printed by `my-agent` itself ([Any agent](any-agent.md)). Linux and Windows, no. lmux is native AppKit on libghostty, and a port would be a different app.

## Does it phone home?

No. lmux makes no network calls at all. No telemetry, no crash reports, not even an update check (Homebrew does that). Everything it writes to disk, and how to remove it, is in [Privacy & files on disk](privacy.md).

## Will lmux get an in-app browser or computer use?

No. Putting a browser engine in the terminal would defeat the whole point. Claude Code already drives browsers and your screen through MCP servers (Playwright, for one) and Claude in Chrome, and lmux is just the terminal Claude Code runs in. If you want to script lmux itself, the bundled [`lmux` CLI](cli.md) can list panes, send input to them and wait for an agent to finish ([`lmux wait`](cli.md#lmux-wait)), so Claude can start a Codex review in a new workspace and read the result. See [lmux for agents](https://github.com/sooftware/lmux/blob/main/docs/agents.md).

## Why "lmux"?

The l is for light. Say it "el-mux."

## Will you add feature X?

Only if it stays light. Either way, [open an issue](https://github.com/sooftware/lmux/issues) and tell me who it's for.

## When is lmux not for me?

- You use cmux's in-app browser, SSH workspaces, ports and PR widgets, custom commands, or more scripting than `lmux send` and `lmux new-workspace` give you.
- You need Linux or Windows.
- You want the knobs. cmux has about two hundred of them.

Then use cmux. It's great.
