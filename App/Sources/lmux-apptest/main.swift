// lmux app harness: drives the real LmuxController headlessly (no window on
// screen, no focus change, no system notifications) through synthesized
// keys/clicks, the real hook socket and the real CLI.
//
//   lmux-apptest                 workspaces, splits, focus, hooks, CLI, installer; saves layout
//   lmux-apptest --restore       relaunch on the saved layout and check the round trip
//   lmux-apptest --newuser       a new user's first days: README shortcuts, user keybinds, edge cases, cmux leftovers
//   lmux-apptest --compat        real programs outside the happy path (see Compat.swift)
//   lmux-apptest --parity        Ghostty parity: scrollback scroller, link hover / ⌘-click
//   lmux-apptest --titlebar      titlebar buttons + ⇧⌘H in the real titled chrome (never shown)
//   lmux-apptest --attention     unattended rows breathe after the reminder delay (fake clock), idle CPU
//   lmux-apptest --status-extras subagent count, bypass / auto badge, usage-limit wait, quiet hint (fake clock);
//                                --status-extras-shots D: their dark / light PNGs
//   lmux-apptest --settings      Settings window, theme / font writes + live reload, cmux import (fixtures)
//   lmux-apptest --cmux-real D   dry-run the cmux import on a COPY of real cmux files (LMUX_CMUX_HOME), PNGs into D
//   lmux-apptest --bell          the bell's notification list (rows, read state, keys, cap)
//   lmux-apptest --sidebar       row × on hover, ⌘/⇧-click multi-selection, closing (idle shells, busy panes)
//   lmux-apptest --zoom-clear-reorder  split zoom, Clear Status, sidebar drag-to-reorder
//   lmux-apptest --pane-tabs     tabs in a pane (keys, strip, status, splits, CLI, layout); --pane-tabs-restore: the relaunch
//   lmux-apptest --new-workspace-dir   where ⌘N / splits start (Ghostty's working-directory keys);
//                                      --new-workspace-dir-restore: a relaunch keeps saved directories
//   lmux-apptest --big           a fresh process: 50MB transcript, memory budget, incremental parsing
//   lmux-apptest --contrast      text stays readable across theme pairs (pixels; --contrast-matrix D: QA report)
//   lmux-apptest --screenshots D render dark/light window PNGs into D
//   lmux-apptest --readme D      README hero PNGs + GIFs (App/scripts/readme.sh), --readme-light D: light.gif
//   lmux-apptest --hero D [--light]  the hero video's frames, poster and still (readme.sh hero)
//   lmux-apptest --codex         Codex CLI: a fake codex sends real payloads through lmux-hook (temp CODEX_HOME);
//                                --codex-restore checks the saved Codex pane comes back with codex resume
//   lmux-apptest --agents        any program's own status (OSC 7501 app=), lmux wait, lmux list --json
//   lmux-apptest --gpu-idle      idle surfaces release / rebuild GPU resources (scripts/ghostty.patch) under stress
//   lmux-apptest --codex-real    the real Codex CLI against a mock model (App/scripts/codexreal.sh), then --codex-real-restore
//   lmux-apptest --scrollback    plain shell panes save their output at quit; --scrollback-restore shows it again
//   lmux-apptest --security      pane tokens, external send, typed commands, transcript paths, links, socket caps
//   lmux-apptest --rewind        ✎ × ⌘Z on a faithful fake of Claude Code's rewind menu (also in the main pass)
//   lmux-apptest --e2e-bench     real Claude Code: rewind timings, back-outs, menu frames (RewindBench.swift)
//   lmux-apptest --e2e           real Claude Code (offline, mock API) edit / remove / undo / copy, see E2E.swift
//   lmux-apptest --e2e-hover     real Claude Code: the hover band, pill and × on each turn, see E2EHover.swift
//   lmux-apptest --e2e-running   real Claude Code: ✎ / × on the turn Claude is still on, see E2ERunning.swift
//
// Needs (set by App/scripts/apptest.sh): LMUX_HEADLESS=1, LMUX_STATE_DIR,
// LMUX_PANE_COMMAND (sink script), LMUX_SINK_DIR, LMUX_BIN_DIR.

import AppKit
import GhosttyKit
import LmuxHooks
import LmuxTerminal
@testable import LmuxUI

// The History indexer helper (the harness points HistoryModel.helper at itself).
if let code = HistoryIndexer.runIfRequested() { exit(code) }

// Never the user's real state dir (layout.json, sockets).
if (ProcessInfo.processInfo.environment["LMUX_STATE_DIR"] ?? "").isEmpty {
    print("lmux-apptest: set LMUX_STATE_DIR to a temp dir (App/scripts/apptest.sh does)")
    exit(2)
}

// Same clean pane environment as the app (before ghostty_init, see sanitizeInheritedEnvironment).
LmuxController.sanitizeInheritedEnvironment()

if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
    print("ghostty_init failed")
    exit(2)
}
setvbuf(stdout, nil, _IOLBF, 0)
let app = NSApplication.shared
// Never in the Dock or ⌘Tab, never activated (--real-window, CI only, switches to .regular).
app.setActivationPolicy(.prohibited)

final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let args = CommandLine.arguments
            let code: Int32
            if args.contains("--real-window") {
                code = await runRealWindow()
            } else if args.contains("--regressions") {
                code = await runRegressions()
            } else if args.contains("--scrollback-restore") {
                code = await runScrollbackRestore()
            } else if args.contains("--scrollback") {
                code = await runScrollback()
            } else if args.contains("--gpu-idle") {
                code = await runGpuIdle()
            } else if args.contains("--codex-real-restore") {
                code = await runCodexRealRestore()
            } else if args.contains("--codex-real") {
                code = await runCodexReal()
            } else if args.contains("--codex-restore") {
                code = await runCodexRestore()
            } else if args.contains("--agents") {
                code = await runAgents()
            } else if args.contains("--codex") {
                code = await runCodex()
            } else if args.contains("--e2e-bench") {
                code = await runRewindBench()
            } else if args.contains("--e2e-hover") {
                code = await runE2EHover()
            } else if args.contains("--e2e-running") {
                code = await runE2ERunning()
            } else if args.contains("--e2e") {
                code = await runE2E()
            } else if args.contains("--rewind") {
                code = await runRewind()
            } else if args.contains("--newuser") {
                code = await runNewUser()
            } else if args.contains("--security") {
                code = await runSecurity()
            } else if args.contains("--contrast-cost") {
                code = await runContrastCost()
            } else if args.contains("--contrast") {
                code = await runContrast()
            } else if let i = args.firstIndex(of: "--contrast-matrix"), i + 1 < args.count {
                code = await runContrastMatrix(URL(fileURLWithPath: args[i + 1]))
            } else if args.contains("--compat") {
                code = await runCompat()
            } else if args.contains("--parity") {
                code = await runParity()
            } else if args.contains("--status-extras") {
                code = await runStatusExtras()
            } else if args.contains("--attention") {
                code = await runAttention()
            } else if args.contains("--settings") {
                code = await runSettings()
            } else if let i = args.firstIndex(of: "--settings-shots"), i + 1 < args.count {
                code = await runSettingsShots(URL(fileURLWithPath: args[i + 1]))
            } else if let i = args.firstIndex(of: "--cmux-real"), i + 1 < args.count {
                code = await runCmuxReal(URL(fileURLWithPath: args[i + 1]))
            } else if args.contains("--bell") {
                code = await runBell()
            } else if let i = args.firstIndex(of: "--bell-shots"), i + 1 < args.count {
                code = await runBellShots(URL(fileURLWithPath: args[i + 1]))
            } else if args.contains("--sidebar") {
                code = await runSidebar()
            } else if args.contains("--new-workspace-dir-restore") {
                code = await runNewWorkspaceDirRestore()
            } else if args.contains("--new-workspace-dir") {
                code = await runNewWorkspaceDir()
            } else if args.contains("--pane-tabs-restore") {
                code = await runPaneTabsRestore()
            } else if args.contains("--pane-tabs") {
                code = await runPaneTabs()
            } else if args.contains("--zoom-clear-reorder") {
                code = await runZoomClearReorder()
            } else if args.contains("--esc-idle") {
                code = await runEscIdle()
            } else if args.contains("--titlebar") {
                code = await runTitlebar()
            } else if args.contains("--latency") {
                code = await runLatency()
            } else if args.contains("--big") {
                code = await runBigTranscript()
            } else if args.contains("--restore") {
                code = await runRestore()
            } else if let i = args.firstIndex(of: "--readme"), i + 1 < args.count {
                code = await runReadme(URL(fileURLWithPath: args[i + 1]))
            } else if let i = args.firstIndex(of: "--hero"), i + 1 < args.count {
                code = await runHero(URL(fileURLWithPath: args[i + 1]), light: args.contains("--light"))
            } else if let i = args.firstIndex(of: "--readme-light"), i + 1 < args.count {
                code = await runReadmeLight(URL(fileURLWithPath: args[i + 1]))
            } else if let i = args.firstIndex(of: "--feedback-shots"), i + 1 < args.count {
                code = await runFeedbackShots(URL(fileURLWithPath: args[i + 1]))
            } else if let i = args.firstIndex(of: "--status-extras-shots"), i + 1 < args.count {
                code = await runStatusExtrasShots(URL(fileURLWithPath: args[i + 1]))
            } else if let i = args.firstIndex(of: "--polish-shots"), i + 1 < args.count {
                code = await runPolishShots(URL(fileURLWithPath: args[i + 1]))
            } else if let i = args.firstIndex(of: "--screenshots"), i + 1 < args.count {
                code = await runScreenshots(URL(fileURLWithPath: args[i + 1]))
            } else {
                code = await runMain()
            }
            fflush(stdout)
            _exit(code)
        }
    }
}

let delegate = Delegate()
app.delegate = delegate
app.run()
