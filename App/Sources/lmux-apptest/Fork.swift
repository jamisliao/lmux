import AppKit
@testable import LmuxUI

// Fork Session (#10): a new tab after the pane, in its directory, typing the pane's resume command
// plus `--fork-session` with its session's env; the pane itself untouched. Enabled only for a pane
// whose Claude Code session lmux knows (not a plain shell, not Codex). Part of the main pass.
@MainActor
func forkChecks(_ r: Report, _ c: LmuxController) async {
    r.section = "fork session"
    let ws = c.newWorkspace()
    let p = ws.panes[0]
    _ = await sinks.waitReady(p.id)
    let item = NSMenuItem(title: "Fork Session", action: #selector(LmuxController.menuForkSession(_:)), keyEquivalent: "")
    r.check("a plain shell: Fork Session disabled (tab menu and Workspace menu), nothing opens",
            c.tabMenu(for: p).item(withTitle: "Fork Session")?.isEnabled == false && !c.validateMenuItem(item)
            && c.forkSession(p) == nil && ws.panes.count == 1)

    let sid = "8e1f0c2a-0000-4000-8000-00000000f0a1"
    hookEvent(c, p, "SessionStart", session: sid, ["source": "startup"])
    // As captureResumeCommand leaves them for a claude started with flags and CLAUDE_CONFIG_DIR.
    p.resumeCommand = "/opt/bin/claude --model opus --permission-mode plan --resume \(sid)"
    p.resumeEnvironment = ["CLAUDE_CONFIG_DIR": "/tmp/lmux fork claude"]
    let want = " /opt/bin/claude --model opus --permission-mode plan --resume \(sid) --fork-session\n"
    r.check("the fork's command: the restore command (flags kept) plus --fork-session",
            LmuxController.forkCommand(p) == want, LmuxController.forkCommand(p) ?? "nil")
    r.check("…enabled in the tab menu and the Workspace menu",
            c.tabMenu(for: p).item(withTitle: "Fork Session")?.isEnabled == true && c.validateMenuItem(item))

    let before = (p.claudeSessionID, p.resumeCommand, p.resumeEnvironment, p.agentKind)
    let ran = run(c.tabMenu(for: p), "Fork Session")
    let leaf = ws.root.find(p)
    let fork = leaf?.tabs.last
    r.check("Fork Session: a new tab right after the pane, shown and focused, its own pane",
            ran && leaf?.tabs.count == 2 && leaf?.tabs.first === p && fork !== p && ws.focusedPane === fork
            && leaf?.shownTab === fork, "\(leaf?.tabs.map(\.id) ?? [])")
    if let fork {
        _ = await sinks.waitReady(fork.id)
        let typed = await sinks.wait(fork.id, contains: "--fork-session")
        r.check("…types the fork command into its shell", typed && sinks.text(fork.id).contains(
            "/opt/bin/claude --model opus --permission-mode plan --resume \(sid) --fork-session"), sinks.text(fork.id))
        let envFile = sinks.dir.appendingPathComponent("\(fork.id).env")
        let forkEnv = (try? String(contentsOf: envFile, encoding: .utf8)) ?? ""
        r.check("…in the pane's directory, with its session's env in the shell (never typed)",
                fork.cwd == p.cwd && forkEnv.contains("CLAUDE_CONFIG_DIR=/tmp/lmux fork claude")
                && !sinks.text(fork.id).contains("CLAUDE_CONFIG_DIR"), "\(fork.cwd ?? "nil") vs \(p.cwd ?? "nil")")
        r.check("…no session until the fork's own SessionStart (the new id, not the original's)", fork.claudeSessionID == nil)
        hookEvent(c, fork, "SessionStart", session: "8e1f0c2a-0000-4000-8000-00000000f0a2", ["source": "resume"])
        r.check("…which binds the fork's own session, like any other tab",
                fork.claudeSessionID == "8e1f0c2a-0000-4000-8000-00000000f0a2" && ws.panes.count == 2)
    }
    r.check("the original pane is untouched: same session, command, env, nothing typed into it",
            p.claudeSessionID == before.0 && p.resumeCommand == before.1 && p.resumeEnvironment == before.2
            && p.agentKind == before.3 && !sinks.text(p.id).contains("fork-session"), sinks.text(p.id))

    p.agentKind = .codex
    r.check("a Codex session: Fork Session disabled (no fork by session id)",
            LmuxController.forkCommand(p) == nil && c.tabMenu(for: p).item(withTitle: "Fork Session")?.isEnabled == false)

    for q in ws.panes where q.runsClaude { hookEvent(c, q, "SessionEnd", session: q.claudeSessionID!) }
    c.closeWorkspace(ws)
}
