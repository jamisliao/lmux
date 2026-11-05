import AppKit
@testable import LmuxUI

// A cmux 0.65 setup as cmux really writes it (structure, key names and value types taken from a
// real install; every path, name and id here is made up): the Ghostty config with cmux's theme
// markers, the settings.json template with its commented block, the defaults plist with its JSON
// blobs and unrelated keys, and a session whose panels carry the full terminal / agent /
// resumeBinding records, browser panels mixed into splits, tabs, a Codex pane, another agent's pane and a second window.

enum CmuxReal {
    static let sid = ["4d2c9a10-7f3e-4b1a-9c8d-0e1f2a3b4c5d", "5e3dab21-8a4f-4c2b-8d9e-1f2a3b4c5d6e"]
    static let codexSid = "6f4ebc32-9b5a-4d3c-8eaf-2a3b4c5d6e7f"
    /// An agent lmux has no resume for.
    static let otherSid = "7a5fcd43-ac6b-4e4d-9fb0-3b4c5d6e7f80"
    static let missingDir = "/Users/demo/없는 폴더/プロジェクト"
    /// Not a UUID (and shell syntax): never typed after `--resume`.
    static let badSid = "4d2c9a10; touch /tmp/lmux-pwned"
}

/// Writes the fixture into `home` (a HOME-like dir) and returns cmux's files.
func writeCmuxRealFixture(_ home: URL) -> [URL] {
    let fm = FileManager.default
    let src = CmuxSources(home: home)
    for u in src.allFiles { try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true) }
    try? """
    # cmux themes start
    theme = light:Nord,dark:Nord
    # cmux themes end

    # 주 폰트: D2Coding (한글 폭 정렬). 뒤의 항목은 없는 글리프용 폴백(Nerd 아이콘).
    font-family = D2Coding
    font-family = Pravka Nerd Font Mono

    """.write(to: src.ghosttyConfig, atomically: true, encoding: .utf8)
    func settings(_ schema: String) -> String {
        """
        {
          "$schema": "https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/\(schema).schema.json",
          "schemaVersion": 1,

          "app": {
            "appearance": "dark"
          },

          "sidebarAppearance": {
            "matchTerminalBackground": true
          },

          // This file uses JSON with comments (JSONC).
          // Uncomment and edit any setting to make it file-managed.

          //   "app" : {
          //     "appearance" : "system",
          //     "warnBeforeQuit" : true
          //   },

          //   "shortcuts" : {
          //     "bindings" : {
          //       "browserBack" : "cmd+[",
          //       "toggleSplitZoom" : "cmd+shift+\\r",
          //       "splitRight" : "cmd+d"
          //     },
          //     "showModifierHoldHints" : true
          //   },
        }

        """
    }
    try? settings("cmux-settings").write(to: src.settingsFiles[0], atomically: true, encoding: .utf8)
    try? settings("cmux").write(to: src.settingsFiles[1], atomically: true, encoding: .utf8)

    let display: [String: Any] = ["displayID": 1, "stableID": "uuid:00000000-0000-4000-8000-0000000000D1",
                                  "frame": ["height": 1117, "width": 1728, "x": 0, "y": 0],
                                  "visibleFrame": ["height": 997, "width": 1728, "x": 0, "y": 87]]
    let frame: [String: Any] = ["height": 997, "width": 1728, "x": 0, "y": 87]
    func json(_ o: Any) -> Data { (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data() }
    func custom(title: String?, color: String?) -> [String: Any] {
        ["customization": ["customTitle": title.map { ["value": ["_0": $0]] } ?? ["absent": [:]],
                           "customColor": color.map { ["value": ["_0": $0]] } ?? ["absent": [:]]],
         "revision": 3]
    }
    let customizations: [String: Any] = ["nextRevision": 9, "version": 1, "entries": [
        "00000000-0000-4000-8000-00000000A0A1": custom(title: "api 서버", color: nil),
        "00000000-0000-4000-8000-00000000B0B1": custom(title: "notes from the plist", color: nil),
        "00000000-0000-4000-8000-00000000D0D1": custom(title: nil, color: "#196F3D"),
        "00000000-0000-4000-8000-0000000000FF": custom(title: "a closed workspace", color: "#AD1457"),
    ]]
    let plist: [String: Any] = [
        "appearanceMode": "dark", "warnBeforeQuitShortcut": false, "sidebarMatchTerminalBackground": true,
        "sidebarTintHex": "#000000", "sidebarTintOpacity": 0.18, "rightSidebar.mode": "files", "SUEnableAutomaticChecks": true,
        "NSWindow Frame SwiftUI.ModifiedContent<cmux.ContentView>-1-AppWindow-1": "153 90 1381 960 0 0 1728 1084 ",
        "browserProfiles.v1": json([["isBuiltInDefault": true, "id": "00000000-0000-4000-8000-0000000000B9", "displayName": "Default"]]),
        "cmux.session.lastWindowGeometry.v2": json(["display": display, "frame": frame, "version": 2]),
        "workspaceCustomizations.v2": json(customizations),
        "fileExplorer.width": 295.0, "cmux.analytics.lastVersion": "0.65.2",
    ]
    try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: src.defaultsPlist)

    func launch(_ dir: String, _ exe: String) -> [String: Any] {
        ["arguments": [exe], "capturedAt": 1793370616.57, "executablePath": exe, "launcher": (exe as NSString).lastPathComponent,
         "source": "environment", "workingDirectory": dir]
    }
    func terminal(_ id: String, _ dir: String, title: String, agent: String? = nil, session: String? = nil) -> [String: Any] {
        var t: [String: Any] = ["hasReceivedExplicitInput": true, "isRemoteTerminal": false, "workingDirectory": dir]
        if let agent, let session {
            let exe = "/Users/demo/.local/bin/\(agent)"
            t["agent"] = ["hadActivePromptTurn": false, "kind": agent, "launchCommand": launch(dir, exe), "permissionMode": "auto",
                          "sessionId": session, "workingDirectory": dir]
            t["resumeBinding"] = ["approvalPolicy": "auto", "autoResume": true, "checkpointId": session, "cwd": dir, "kind": agent,
                                  "command": "cd -- '\(dir)' 2>/dev/null || [ ! -d '\(dir)' ] && /bin/sh -c '\(agent) --resume \(session)'",
                                  "launchCommand": launch(dir, exe), "launchFlavor": ["kind": "local"], "name": "Claude Code",
                                  "permissionMode": "auto", "source": "agent-hook", "updatedAt": 1793581836.68]
            t["wasAgentRunning"] = true
        }
        return ["directory": dir, "directoryIsTrustedRemoteReport": false, "hasUnreadIndicator": false, "id": id,
                "isManuallyUnread": false, "isPinned": false, "listeningPorts": [], "stableSurfaceId": id + "-S",
                "terminal": t, "title": title, "ttyName": "ttys005", "type": "terminal"]
    }
    func browser(_ id: String) -> [String: Any] {
        ["browser": ["backHistoryURLStrings": [], "chromeVisibility": "visible", "developerToolsVisible": false,
                     "forwardHistoryURLStrings": [], "interactionState": "AAAAAmJwbGlzdDAw", "url": "https://example.invalid/"],
         "directoryIsTrustedRemoteReport": false, "hasUnreadIndicator": false, "id": id, "isManuallyUnread": false,
         "isPinned": false, "listeningPorts": [], "stableSurfaceId": id + "-S", "title": "Example", "type": "browser"]
    }
    func leaf(_ ids: [String], selected: String? = nil) -> [String: Any] {
        ["pane": ["isFullWidthTabMode": false, "panelIds": ids, "selectedPanelId": selected ?? ids[0]], "type": "pane"]
    }
    func split(_ o: String, _ d: Double, _ a: [String: Any], _ b: [String: Any]) -> [String: Any] {
        ["split": ["dividerPosition": d, "first": a, "orientation": o, "second": b], "type": "split"]
    }
    func workspace(_ id: String, stable: String, title: String?, dir: String, focused: String, layout: [String: Any],
                   panels: [[String: Any]], color: String? = nil) -> [String: Any] {
        var w: [String: Any] = ["currentDirectory": dir, "focusedPanelId": focused, "hasUnreadIndicator": false, "isManuallyUnread": false,
                                "isMuted": false, "isPinned": false, "layout": layout, "layoutMode": "splits", "logEntries": [],
                                "panels": panels, "processTitle": "zsh", "stableId": stable, "taskStatusHidden": true, "workspaceId": id,
                                "statusEntries": [["color": "#8E8E93", "icon": "hourglass", "key": "claude_code", "timestamp": 1793581836.6,
                                                   "value": "Waiting"]]]
        if let title { w["customTitle"] = title; w["customTitleSource"] = "user" }
        if let color { w["customColor"] = color }
        return w
    }
    let home0 = "/Users/demo"
    let ws: [[String: Any]] = [
        // A: one Claude pane, named in the session.
        workspace("00000000-0000-4000-8000-00000000A0A0", stable: "00000000-0000-4000-8000-00000000A0A1", title: "api 서버",
                  dir: home0, focused: "A-T1", layout: leaf(["A-T1"]),
                  panels: [terminal("A-T1", "\(home0)/code/api", title: "로그인 버그 고치기", agent: "claude", session: CmuxReal.sid[0])]),
        // B (selected in cmux): no name in the session, only in the plist's customizations.
        workspace("00000000-0000-4000-8000-00000000B0B0", stable: "00000000-0000-4000-8000-00000000B0B1", title: nil,
                  dir: home0, focused: "B-T1", layout: leaf(["B-T1"]),
                  panels: [terminal("B-T1", home0, title: "zsh", agent: "opencode", session: CmuxReal.otherSid)]),
        // C: [Claude | [browser / (shell tab, shell tab)]]; the browser goes, its split closes up.
        workspace("00000000-0000-4000-8000-00000000C0C0", stable: "00000000-0000-4000-8000-00000000C0C1", title: "split 🚀 작업",
                  dir: "/tmp", focused: "C-T3",
                  layout: split("horizontal", 0.5, leaf(["C-T1"]), split("vertical", 0.3, leaf(["C-B1"]), leaf(["C-T2", "C-T3"], selected: "C-T3"))),
                  panels: [terminal("C-T1", "/tmp", title: "refactor", agent: "claude", session: CmuxReal.sid[1]), browser("C-B1"),
                           terminal("C-T2", "/tmp", title: "zsh"), terminal("C-T3", "/private/tmp", title: "tail -f")]),
        // D: a folder that no longer exists, color from the customizations, a very long name.
        workspace("00000000-0000-4000-8000-00000000D0D0", stable: "00000000-0000-4000-8000-00000000D0D1",
                  title: String(repeating: "아주 긴 이름 ", count: 20), dir: CmuxReal.missingDir, focused: "D-T1",
                  layout: leaf(["D-T1"]), panels: [terminal("D-T1", CmuxReal.missingDir, title: "zsh", agent: "claude", session: CmuxReal.badSid)]),
        // E: Codex.
        workspace("00000000-0000-4000-8000-00000000E0E0", stable: "00000000-0000-4000-8000-00000000E0E1", title: "codex",
                  dir: "/tmp", focused: "E-T1", layout: leaf(["E-T1"]),
                  panels: [terminal("E-T1", "/tmp", title: "codex", agent: "codex", session: CmuxReal.codexSid)], color: "#C0392B"),
        // F: only a browser: nothing to open.
        workspace("00000000-0000-4000-8000-00000000F0F0", stable: "00000000-0000-4000-8000-00000000F0F1", title: "docs",
                  dir: home0, focused: "F-B1", layout: leaf(["F-B1"]), panels: [browser("F-B1")]),
    ]
    let second = workspace("00000000-0000-4000-8000-0000000002A0", stable: "00000000-0000-4000-8000-0000000002A1", title: "second window",
                           dir: "/tmp", focused: "W2-T1", layout: leaf(["W2-T1"]), panels: [terminal("W2-T1", "/tmp", title: "zsh")])
    func window(_ id: String, _ w: [[String: Any]], selected: Int) -> [String: Any] {
        ["configFrames": [["display": display, "frame": frame, "lastUsedAt": 1793581949.44,
                           "signature": "uuid:00000000-0000-4000-8000-0000000000D1@0,0,1728x1117"]],
         "display": display, "frame": frame, "sidebar": ["isVisible": true, "selection": "tabs", "width": 240],
         "tabManager": ["selectedWorkspaceIndex": selected, "workspaces": w], "windowId": id]
    }
    let session: [String: Any] = ["createdAt": 1793581949.43, "scrollbackCapturedAt": 1793581949.43, "version": 1,
                                  "windows": [window("00000000-0000-4000-8000-0000000000C1", ws, selected: 1),
                                              window("00000000-0000-4000-8000-0000000000C2", [second], selected: 0)]]
    try? JSONSerialization.data(withJSONObject: session, options: [.sortedKeys]).write(to: src.session)
    return src.allFiles
}

/// `--settings`: the import on the real cmux format (see above).
@MainActor
func checkCmuxReal(_ r: Report, _ c: LmuxController) async {
    r.section = "cmux import (real format)"
    let home = paths.stateDir.appendingPathComponent("cmux-real-home", isDirectory: true)
    let files = writeCmuxRealFixture(home)
    let before = files.map(sha)
    let plan = CmuxImport.plan(CmuxSources(home: home))
    r.check("look: Nord, D2Coding + the Nerd Font fallback (the comment line skipped)",
            plan.configLines == ["theme = light:Nord,dark:Nord", "font-family = \"\"", "font-family = D2Coding", "font-family = Pravka Nerd Font Mono"],
            "\(plan.configLines)")
    r.check("app: dark, quit without asking, the window's frame, sidebar 240 shown, matching the terminal",
            plan.appearance == .dark && plan.warnBeforeQuit == false && plan.windowFrame == NSRect(x: 0, y: 87, width: 1728, height: 997)
            && plan.sidebarWidth == 240 && plan.sidebarVisible == true && plan.sidebarMatch == true)
    r.check("nothing customized: no notification or shortcut section (commented template ignored)",
            !plan.has(.notifications) && !plan.has(.shortcuts) && plan.keybinds.isEmpty)
    let ids = plan.workspaces.map(\.id)
    let wid = { (k: String) in "cmux-00000000-0000-4000-8000-00000000\(k)0\(k)0" }
    r.check("every window's workspaces, in order; the browser-only one skipped",
            ids == [wid("A"), wid("B"), wid("C"), wid("D"), wid("E"), "cmux-00000000-0000-4000-8000-0000000002A0"], "\(ids)")
    let byID = Dictionary(uniqueKeysWithValues: plan.workspaces.map { ($0.id, $0) })
    r.check("names from the session, else from the plist's customizations", byID[wid("A")]?.customTitle == "api 서버"
            && byID[wid("B")]?.customTitle == "notes from the plist" && byID[wid("C")]?.customTitle == "split 🚀 작업")
    r.check("colors: the session's, else the customizations' (nearest accent)",
            byID[wid("E")]?.accent == CmuxImport.nearestAccent("#C0392B") && byID[wid("D")]?.accent == CmuxImport.nearestAccent("#196F3D"))
    r.check("cmux's selected workspace is the one selected", plan.selectedWorkspace == wid("B"))
    let cRoot = byID[wid("C")]?.root
    r.check("browser dropped from the split: [Claude | the tab that was showing], 0.5, horizontal",
            cRoot?.axis == .horizontal && cRoot?.ratio == 0.5 && cRoot?.children?.map { $0.pane?.id } == ["cmux-C-T1", "cmux-C-T3"]
            && cRoot?.children?[1].pane?.cwd == "/private/tmp" && byID[wid("C")]?.focusedPane == "cmux-C-T3")
    r.check("a pane's two terminals come over as its two tabs, the one that was showing selected",
            cRoot?.children?[1].tabs?.map(\.id) == ["cmux-C-T2", "cmux-C-T3"] && cRoot?.children?[1].selectedTab == 1,
            "\(cRoot?.children?[1].tabs?.map(\.id) ?? [])")
    let codexPane = byID[wid("E")]?.root.pane
    r.check("Claude panes resume with cmux's permission mode; Codex resumes too; another agent opens a shell",
            byID[wid("A")]?.root.pane?.resumeCommand == "claude --permission-mode auto --resume \(CmuxReal.sid[0])"
            && cRoot?.children?[0].pane?.claudeSession == CmuxReal.sid[1] && codexPane?.agent == "codex"
            && codexPane?.claudeSession == CmuxReal.codexSid && (codexPane?.resumeCommand ?? "").hasSuffix("resume \(CmuxReal.codexSid)")
            && byID[wid("B")]?.root.pane?.claudeSession == nil && byID[wid("B")]?.root.pane?.resumeCommand == nil,
            "\(codexPane?.resumeCommand ?? "-")")
    let ni = plan.notImported.joined(separator: " | ")
    r.check("listed as not imported: 2 browser panes, the opencode session (not Codex), the browser-only workspace; not the tab",
            ni.contains("2 browser panes") && !ni.contains("more tab") && ni.contains("1 opencode session") && !ni.contains("Codex session")
            && ni.contains("1 workspace with no terminal")
            && !ni.contains("Setting “"), ni)

    let result = c.importFromCmux(plan, sections: [.workspaces])
    r.check("Import: 6 workspaces, cmux's selected one selected", result.contains("6 workspaces") && c.model.selected?.id == wid("B")
            && c.model.selected?.title == "notes from the plist", "\(result) \(c.model.selected?.title ?? "-")")
    let wsC = c.model.workspaces.first { $0.id == wid("C") }
    r.check("…the split opens with 2 panes (one of them 2 tabs), the focused one focused",
            wsC?.visiblePanes.count == 2 && wsC?.panes.map(\.id) == ["cmux-C-T1", "cmux-C-T2", "cmux-C-T3"]
            && wsC?.focusedPane?.id == "cmux-C-T3" && wsC?.root.find(wsC!.focusedPane!)?.hasTabs == true,
            "\(wsC?.panes.map(\.id) ?? [])")
    let typed = await sinks.wait("cmux-A-T1", contains: "claude --permission-mode auto --resume \(CmuxReal.sid[0])", timeout: 5)
    r.check("…the Claude pane types its resume line", typed, sinks.text("cmux-A-T1"))
    let codexTyped = await sinks.wait("cmux-E-T1", contains: "resume \(CmuxReal.codexSid)", timeout: 5)
    r.check("…the Codex pane types its resume line", codexTyped && sinks.text("cmux-E-T1").contains("codex resume"), sinks.text("cmux-E-T1"))
    let wsD = c.model.workspaces.first { $0.id == wid("D") }
    r.check("…the missing folder still opens (a shell, not an error)", wsD?.panes.count == 1)
    r.check("…a session id that isn't a UUID: a plain shell, nothing typed", byID[wid("D")]?.root.pane?.resumeCommand == nil
            && wsD?.panes.first?.claudeSessionID == nil && !sinks.text("cmux-D-T1").contains("--resume"))
    r.check("…resume lines start with a space (kept out of shell history)", sinks.text("cmux-A-T1").hasPrefix(" claude "), sinks.text("cmux-A-T1"))
    r.check("cmux's files are byte-identical afterwards", files.map(sha) == before)
}
