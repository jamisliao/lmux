# Security policy

## Reporting a vulnerability

Please report security issues privately through GitHub's
[private vulnerability reporting](https://github.com/sooftware/lmux/security/advisories/new)
(Security tab > "Report a vulnerability") rather than opening a public issue. This lets us fix
the problem before it's public.

If private reporting isn't available for some reason, open an issue that says only "security
issue, requesting contact" with no details, and we'll follow up to get a private channel going.

We'll acknowledge reports as soon as we can and keep you updated as a fix is worked out.

## Scope

Things that are specifically in scope, because lmux touches them on your machine:

- **The hooks installer** (`Core/Sources/LmuxHooks`, `App/Sources/LmuxUI/HooksSetup.swift`) —
  it edits your Claude Code `~/.claude/settings.json` to add lmux's hooks, and is meant to
  restore it exactly on uninstall. A bug that corrupts `settings.json`, leaves stray entries
  behind, or installs something other than what the shown diff said, is a security-relevant bug.
- **Transcripts and the message actions** (`Core/Sources/LmuxTranscript`, `Core/Sources/LmuxSessions`,
  `App/Sources/LmuxUI/Rewind.swift`) — lmux reads Claude Code session files, archives them for
  History, and drives Claude Code's own rewind menu for "edit & resend", "remove" and undo send.
  A bug that corrupts a transcript, makes a rewind pick the wrong turn or a code-restoring option,
  or exposes/writes session content outside the session it came from, is in scope.
- **The control socket** (`~/Library/Application Support/lmux/control.sock`, and the per-pane
  hook socket) — local Unix sockets that `lmux-cli` and the Claude Code hook binary talk to.
  Anything that lets another local process read pane content, inject input, or otherwise act
  through the socket without being the user's own lmux/CLI, is in scope.
- **Environment handling** — how `LMUX_SOCKET`, `LMUX_PANE_ID`, `LMUX_CONTROL_SOCKET`, and
  similar variables are trusted or ignored (e.g. the app deliberately ignoring its own
  `LMUX_SOCKET`/`LMUX_PANE_ID` inherited from its environment). A bug letting a pane's own
  environment spoof another pane's identity is in scope.

Generic crashes, UI glitches, and feature requests are not security issues — please use a
regular [bug report](.github/ISSUE_TEMPLATE/bug_report.yml) for those instead.

## Supported versions

lmux ships one line of releases; security fixes go into the latest release. There's no older
version actively maintained in parallel.
