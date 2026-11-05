import AppKit
import LmuxTerminal
import LmuxTokens
import SwiftUI
@testable import LmuxUI

// `lmux-apptest --cmux-real D`: a dry run of "Import from cmux" against a COPY of a real cmux
// setup (LMUX_CMUX_HOME, a HOME-like dir; refuses the real HOME). Prints the plan and what the
// import made of it (workspaces, split trees, the resume line each Claude pane would type, the
// config block, settings) and renders the sheet and the resulting window into D, light and dark.
// Panes run LMUX_PANE_COMMAND (the harness's sink: nothing starts, typed input lands in a file).

@MainActor
func runCmuxReal(_ dir: URL) async -> Int32 {
    let src = CmuxSources.current
    guard let h = ProcessInfo.processInfo.environment["LMUX_CMUX_HOME"], !h.isEmpty,
          src.home.standardizedFileURL.path != URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path else {
        print("--cmux-real: point LMUX_CMUX_HOME at a copy of the cmux files, never the real HOME")
        return 2
    }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let before = src.allFiles.map(sha)
    let plan = CmuxImport.plan(src)
    print("== plan")
    for s in CmuxImportPlan.Section.allCases { print("[\(s.rawValue)] \((plan.summary[s] ?? []).joined(separator: " · "))") }
    print("configLines:"); plan.configLines.forEach { print("  \($0)") }
    print("keybinds:"); plan.keybinds.forEach { print("  \($0)") }
    print("lmuxShortcuts: \(plan.lmuxShortcuts)")
    print("appearance=\(String(describing: plan.appearance)) warnBeforeQuit=\(String(describing: plan.warnBeforeQuit)) frame=\(String(describing: plan.windowFrame))"
          + " sidebarWidth=\(String(describing: plan.sidebarWidth)) sidebarVisible=\(String(describing: plan.sidebarVisible)) match=\(String(describing: plan.sidebarMatch))")
    print("sound=\(String(describing: plan.sound)) dockBadge=\(String(describing: plan.dockBadge)) ring=\(String(describing: plan.unreadRing))")
    print("selectedWorkspace=\(String(describing: plan.selectedWorkspace))")
    func tree(_ n: LayoutFile.NodeState, _ ind: String) {
        if let p = n.pane {
            print("\(ind)pane \(p.id) cwd=\(p.cwd ?? "-") title=\(p.title ?? "-") session=\(p.claudeSession ?? "-") resume=\(p.resumeCommand ?? "-")")
        } else {
            print("\(ind)split \(n.axis?.rawValue ?? "?") ratio=\(n.ratio.map { String($0) } ?? "-")")
            n.children?.forEach { tree($0, ind + "  ") }
        }
    }
    for (i, w) in plan.workspaces.enumerated() {
        print("ws#\(i) id=\(w.id) title=\(w.customTitle ?? "-") accent=\(w.accent) focused=\(w.focusedPane ?? "-")")
        tree(w.root, "  ")
    }
    print("notImported:"); plan.notImported.forEach { print("  · \($0)") }

    let vm = CmuxImportModel(plan: plan, firstLaunch: true)
    func render<V: View>(_ view: V, _ name: String, dark: Bool) async {
        let v = NSHostingView(rootView: view)
        let holder = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 640, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        holder.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        holder.contentView = v
        v.layoutSubtreeIfNeeded()
        holder.setContentSize(v.fittingSize)
        v.layoutSubtreeIfNeeded()
        await sleepMs(400)
        v.layoutSubtreeIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        let url = dir.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("wrote \(url.path)")
    }
    print("headline: \(plan.headline)")
    print("notImportedLine: \(plan.notImportedLine ?? "-")")
    for dark in [false, true] {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        vm.choosing = false
        await render(CmuxImportView(model: vm), "cmux-real-sheet", dark: dark)
        vm.choosing = true
        await render(CmuxImportView(model: vm), "cmux-real-sheet-choose", dark: dark)
    }
    NSApp.appearance = nil

    let c = makeController()
    let result = c.importFromCmux(plan, sections: Set(CmuxImportPlan.Section.allCases))
    print("== import\nresult: \(result)")
    print("config block:\n" + ((try? String(contentsOf: LmuxConfig.configFile, encoding: .utf8)) ?? "(none)"))
    print("settings: appearance=\(c.settings.appearance) warnBeforeQuit=\(c.settings.warnBeforeQuit) match=\(c.settings.sidebarMatchesTerminal)"
          + " sound=\(String(describing: c.settings.notificationSound)) dockBadge=\(c.settings.dockBadge) ring=\(c.settings.unreadRing)"
          + " frame=\(String(describing: c.importedWindowFrame)) sidebarWidth=\(c.model.sidebarWidth) sidebarVisible=\(c.model.sidebarVisible)")
    print("selected: \(c.model.selected?.id ?? "-") (\(c.model.selected?.title ?? "-"))")
    for w in c.model.workspaces {
        print("lmux ws \(w.id) title=\(w.title) accent=\(w.accent) panes=\(w.panes.count) focused=\(w.focusedPane?.id ?? "-")")
        for p in w.panes {
            var typed = ""
            if p.claudeSessionID != nil {
                _ = await sinks.wait(p.id, contains: "--resume", timeout: 5)
                typed = sinks.text(p.id).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            print("   pane \(p.id) cwd=\(p.cwd ?? "-") session=\(p.claudeSessionID ?? "-") typed=\(typed)")
        }
    }
    await shoot(c, dir, "cmux-real-window")
    vm.result = result
    vm.canUndo = c.cmuxUndo != nil
    for dark in [false, true] {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        await render(CmuxImportView(model: vm), "cmux-real-sheet-done", dark: dark)
    }
    NSApp.appearance = nil
    print("undo: \(c.undoCmuxImport()) workspaces now \(c.model.workspaces.count), config file exists: \(FileManager.default.fileExists(atPath: LmuxConfig.configFile.path))")
    print("cmux files byte-identical: \(src.allFiles.map(sha) == before)")
    c.shutdown()
    return 0
}
