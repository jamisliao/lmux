import AppKit
import LmuxTerminal
@testable import LmuxUI

// `lmux-apptest --new-workspace-dir`: where a new workspace and a split start, from Ghostty's
// `working-directory` and `*-inherit-working-directory` keys. `--new-workspace-dir-restore`: a
// relaunch brings panes back in their saved directories, whatever `working-directory` says.
//
// apptest.sh runs both with LMUX_IGNORE_GHOSTTY_CONFIG=1 (never the user's Ghostty config) and the
// keys written to a temp LMUX_CONFIG_FILE, and a pane program that records its real `pwd -P`.

@MainActor
private struct DirFixture {
    let cfg: URL
    let sink: URL
    let work: String
    let proj: String

    init?() {
        let env = ProcessInfo.processInfo.environment
        guard env["LMUX_IGNORE_GHOSTTY_CONFIG"] == "1", let c = env["LMUX_CONFIG_FILE"], let s = env["LMUX_SINK_DIR"] else {
            print("lmux-apptest --new-workspace-dir: needs LMUX_IGNORE_GHOSTTY_CONFIG=1, LMUX_CONFIG_FILE, LMUX_SINK_DIR (apptest.sh sets them)")
            return nil
        }
        cfg = URL(fileURLWithPath: c)
        sink = URL(fileURLWithPath: s)
        let base = URL(fileURLWithPath: env["LMUX_STATE_DIR"]!).deletingLastPathComponent()
        work = base.appendingPathComponent("work").path
        proj = base.appendingPathComponent("proj").path
        for d in [work, proj] { try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true) }
    }

    func setConfig(_ lines: [String]) {
        try? (lines.joined(separator: "\n") + "\n").write(to: cfg, atomically: true, encoding: .utf8)
    }

    /// The pane process's real working directory (`pwd -P`, written by the pane program).
    func started(_ p: Pane?) async -> String? {
        guard let p else { return nil }
        let f = sink.appendingPathComponent("\(p.id).pwd")
        var s: String?
        _ = await waitFor(5) {
            s = (try? String(contentsOf: f, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            return s?.isEmpty == false
        }
        return s
    }
}

private func real(_ p: String) -> String {
    guard let r = realpath(p, nil) else { return p }
    defer { free(r) }
    return String(cString: r)
}

@MainActor
func runNewWorkspaceDir() async -> Int32 {
    let r = Report()
    guard let fx = DirFixture() else { return 2 }
    let home = NSHomeDirectory()

    // ---------------------------------------------------------- the config keys
    r.section = "start dir: config"
    fx.setConfig([])
    r.check("no config: working-directory is home, new workspaces don't inherit, splits do",
            LmuxConfig.workingDirectory() == home && !LmuxConfig.newWorkspaceInherits() && LmuxConfig.splitInherits())
    r.check("working-directory = ~/Library expands the tilde",
            LmuxConfig.workingDirectory(extra: ["working-directory = ~/Library"]) == home + "/Library")
    r.check("a quoted absolute path is used as is",
            LmuxConfig.workingDirectory(extra: ["working-directory = \"\(fx.proj)\""]) == fx.proj)
    r.check("home / inherit / a missing path / a relative path all mean home",
            ["home", "inherit", fx.proj + "/missing", "proj"].allSatisfy {
                LmuxConfig.workingDirectory(extra: ["working-directory = \($0)"]) == home
            })
    r.check("the last value wins", LmuxConfig.workingDirectory(extra: ["working-directory = \(fx.proj)", "working-directory = home"]) == home)
    r.check("inherit: working-directory = inherit, or window- / tab-inherit-working-directory = true",
            LmuxConfig.newWorkspaceInherits(extra: ["working-directory = inherit"])
                && LmuxConfig.newWorkspaceInherits(extra: ["window-inherit-working-directory = true"])
                && LmuxConfig.newWorkspaceInherits(extra: ["tab-inherit-working-directory = true"])
                && !LmuxConfig.newWorkspaceInherits(extra: ["window-inherit-working-directory = false"])
                && !LmuxConfig.newWorkspaceInherits(extra: ["window-inherit-working-directory = true", "window-inherit-working-directory = false"]))
    r.check("split-inherit-working-directory = false turns split inheritance off",
            !LmuxConfig.splitInherits(extra: ["split-inherit-working-directory = false"])
                && LmuxConfig.splitInherits(extra: ["split-inherit-working-directory = true"]))

    // ---------------------------------------------------------- new workspaces
    r.section = "start dir: new workspace"
    let c = makeController()
    let w = c.window!
    c.assumeAppActive = true
    let first = c.model.workspaces.first?.panes.first
    let firstPwd = await fx.started(first)
    r.check("first launch, no config: the first workspace starts in home", first?.cwd == home && firstPwd == real(home),
            "\(first?.cwd ?? "-") pwd=\(firstPwd ?? "-")")
    let wsWork = c.newWorkspace(cwd: fx.work)
    let workPane = wsWork.panes[0]
    let workPwd = await fx.started(workPane)
    r.check("an explicit directory (lmux new-workspace --cwd) is used as given", workPane.cwd == fx.work && workPwd == real(fx.work),
            "pwd=\(workPwd ?? "-")")

    /// ⌘N with the pane in `work` focused, under `lines`.
    func cmdN(_ lines: [String]) async -> (Pane?, String?) {
        fx.setConfig(lines)
        c.select(wsWork, focusing: workPane)
        let before = c.model.workspaces.count
        await press("n", .command, window: w)
        guard c.model.workspaces.count == before + 1, let ws = c.model.selected, ws !== wsWork else { return (nil, nil) }
        let p = ws.panes.first
        return (p, await fx.started(p))
    }
    func expect(_ name: String, _ got: (Pane?, String?), _ dir: String) {
        r.check(name, got.0?.cwd == dir && got.1 == real(dir), "cwd=\(got.0?.cwd ?? "-") pwd=\(got.1 ?? "-")")
    }
    expect("⌘N, no config: home, not the focused pane's directory", await cmdN([]), home)
    fx.setConfig([])
    c.select(wsWork, focusing: workPane)
    let plus = c.newWorkspace()  // the sidebar's + and the menu item
    expect("+ / File → New Workspace, no config: home", (plus.panes.first, await fx.started(plus.panes.first)), home)
    expect("working-directory = <path>: that path", await cmdN(["working-directory = \"\(fx.proj)\""]), fx.proj)
    expect("working-directory = ~/Library: the expanded path", await cmdN(["working-directory = ~/Library"]), home + "/Library")
    expect("working-directory = home: home", await cmdN(["working-directory = home"]), home)
    expect("working-directory = a missing path: home", await cmdN(["working-directory = \(fx.proj)/missing"]), home)
    expect("working-directory = inherit: the focused pane's directory", await cmdN(["working-directory = inherit"]), fx.work)
    expect("window-inherit-working-directory = true (explicit): the focused pane's directory",
           await cmdN(["working-directory = \(fx.proj)", "window-inherit-working-directory = true"]), fx.work)
    expect("tab-inherit-working-directory = true (explicit): the focused pane's directory",
           await cmdN(["tab-inherit-working-directory = true"]), fx.work)
    expect("window-inherit-working-directory = false: working-directory",
           await cmdN(["working-directory = \(fx.proj)", "window-inherit-working-directory = false"]), fx.proj)

    // ---------------------------------------------------------- splits
    r.section = "start dir: split"
    func cmdD(_ lines: [String], shift: Bool = false) async -> (Pane?, String?) {
        fx.setConfig(lines)
        c.select(wsWork, focusing: workPane)
        let before = wsWork.panes.count
        await press("d", shift ? [.command, .shift] : .command, window: w)
        guard wsWork.panes.count == before + 1, let p = wsWork.focusedPane, p !== workPane else { return (nil, nil) }
        return (p, await fx.started(p))
    }
    expect("⌘D, no config: the pane's directory", await cmdD([]), fx.work)
    expect("⇧⌘D with working-directory set: still the pane's directory", await cmdD(["working-directory = \(fx.proj)"], shift: true), fx.work)
    expect("split-inherit-working-directory = false: working-directory",
           await cmdD(["working-directory = \(fx.proj)", "split-inherit-working-directory = false"]), fx.proj)
    expect("split-inherit-working-directory = false, no working-directory: home",
           await cmdD(["split-inherit-working-directory = false"]), home)

    // For --new-workspace-dir-restore: the `work` workspace and its splits come back in `work`.
    fx.setConfig(["working-directory = \(fx.proj)"])
    return finish(r, c)
}

@MainActor
func runNewWorkspaceDirRestore() async -> Int32 {
    let r = Report()
    r.section = "start dir: restore"
    guard let fx = DirFixture() else { return 2 }
    // working-directory = proj (left by the run above) must not move a restored pane.
    let c = makeController()
    let ws = c.model.workspaces.first { $0.panes.contains { $0.cwd == fx.work } }
    let restored = ws?.panes.filter { $0.cwd == fx.work } ?? []
    var pwds: [String?] = []
    for p in restored { pwds.append(await fx.started(p)) }
    r.check("relaunch with working-directory set: the saved panes come back in their own directory",
            restored.count >= 3 && pwds.allSatisfy { $0 == real(fx.work) },
            "\(restored.count) panes, pwd=\(pwds.map { $0 ?? "-" })")
    return finish(r, c)
}
