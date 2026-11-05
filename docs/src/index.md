# lmux docs

<!-- title: lmux docs: a light macOS terminal for Claude Code and Codex -->

lmux is a light, native macOS terminal for living in Claude Code and Codex all day. It's a 25 MB app on libghostty with a sidebar of workspaces and splits in any direction. It shows which agent is running, done or waiting for you, lets you take back a prompt you sent to the wrong session, and brings every session back after a relaunch. It never wraps `claude` or `codex`. It only listens to their hooks and reads the files they already write.

## Pick your path

<div class="paths">
<a href="install/"><b>New to lmux</b><span class="paths__d">Install it, say yes to the hooks, run <code>claude</code> in a pane.</span><span class="paths__go">Install →</span></a>
<a href="from-cmux/"><b>Coming from cmux</b><span class="paths__d">One click brings over your theme, fonts, shortcuts and open workspaces.</span><span class="paths__go">Switching from cmux →</span></a>
<a href="configuration/"><b>Coming from Ghostty or tmux</b><span class="paths__d">Your Ghostty config is read as is. Workspaces and splits replace tmux sessions.</span><span class="paths__go">Configuration →</span></a>
</div>

## Let your agent set it up

Already in Claude Code or Codex? Paste this, and it reads the [agent guide](https://lmux.dev/agent-guide.md) (one plain Markdown file) and walks you through installing and setting up lmux:

```prompt
Help me set up lmux. Read https://lmux.dev/agent-guide.md first, then walk me through it step by step.
```

## What's in here

- **Start**: [Install](install.md), then [Quick start](quick-start.md) for the first launch and five things to try.
- **Using lmux**: [Workspaces & panes](workspaces.md), every [shortcut](shortcuts.md), [configuration](configuration.md) and [Korean input](korean-input.md).
- **Moving in**: how [lmux compares to cmux](vs-cmux.md), and [moving over from cmux](from-cmux.md) in one click.
- **Agents**: [Claude Code](claude-code.md) (status, rewind, History), [Codex](codex.md), [other agents](any-agent.md) and the [`lmux` CLI](cli.md).
- **Reference**: [performance](performance.md), [privacy and every file lmux writes](privacy.md), [troubleshooting](troubleshooting.md) and the [FAQ](faq.md).
