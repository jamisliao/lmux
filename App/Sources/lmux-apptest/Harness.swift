import AppKit
import QuartzCore
import LmuxUI

// Headless input synthesis for the app harness. Nothing here shows a window,
// activates the app or touches the input source: events are posted to our own
// queue, dequeued (so local monitors and NSApp.currentEvent behave as in real
// dispatch) and routed the way NSApplication routes them.

@MainActor
final class Report {
    var passed = 0, failed = 0
    var section = ""
    func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1 } else { failed += 1 }
        let d = detail()
        print("\(ok ? "PASS" : "FAIL")  [\(section)] \(name)\(d.isEmpty ? "" : "  -- \(d)")")
    }
}

enum KC {
    static let map: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32,
        "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "1": 18, "2": 19, "3": 20, "4": 21, "[": 33, "]": 30,
    ]
}

@MainActor
func sleepMs(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }

/// Allowance for wall-clock and CPU-share budgets on a slow shared machine: `LMUX_CI_SLOW=<factor>`,
/// set only by .github/workflows/ci.yml (GitHub's macOS runners are 3-vCPU VMs shared with other
/// jobs: the same work takes ~1.5-3x the time and CPU share of an M-series laptop, and the main thread
/// can be preempted for a frame or two). Unset (every local run) it is 1: the strict budget.
let ciSlow: Double = max(1, Double(ProcessInfo.processInfo.environment["LMUX_CI_SLOW"] ?? "") ?? 1)

/// Synthesized events go through the app's event queue (so NSApp.currentEvent and local monitors
/// behave as in real dispatch) and are delivered exactly once.
///
/// The queue doesn't always hand a just-posted event back on the spot (under load, with the
/// display asleep): the harness used to deliver it directly then, and the copy left in the queue
/// came out later through the app's run loop, a second time: a bell opened and closed again, a
/// sidebar click replayed after the next one. Now the posted event is waited for (briefly); one
/// that still didn't come is delivered directly and its late copy is dropped when it comes out.
@MainActor
enum SyntheticEvents {
    /// Events delivered directly (type, timestamp): their queued copies are dropped.
    static var deliveredDirectly: [(NSEvent.EventType, TimeInterval)] = []
    private static var monitor: Any?
    static let lateCopies = ProcessInfo.processInfo.environment["LMUX_APPTEST_LATE_COPY"] == "1"
    /// Late copies that came out of the queue and were dropped (tests: the guard works).
    static var droppedLateCopies = 0

    /// `a` is the queue's copy of `b`: same type and time (each synthesized event has its own).
    /// Not the place: the copy sometimes comes back a point or two off (seen: x 100 -> 101, 102,
    /// 125 on an unmoved window). It used to count as "another event": dispatched as is (a
    /// mouse-up away from its mouse-down, so SwiftUI's tap failed) and then ours again, twice.
    static func same(_ a: NSEvent, _ b: NSEvent) -> Bool {
        // (The queue rounds the timestamp: compare to the microsecond.)
        guard a.type == b.type, abs(a.timestamp - b.timestamp) < 1e-5 else { return false }
        if [.keyDown, .keyUp].contains(a.type) { return a.keyCode == b.keyCode }
        return true
    }

    static func isLateCopy(_ e: NSEvent) -> Bool { isLateCopy(e.type, e.timestamp) }
    static func isLateCopy(_ type: NSEvent.EventType, _ timestamp: TimeInterval) -> Bool {
        guard let i = deliveredDirectly.firstIndex(where: { $0.0 == type && abs($0.1 - timestamp) < 1e-5 }) else { return false }
        deliveredDirectly.remove(at: i)
        droppedLateCopies += 1
        return true
    }

    /// Post `e` and take that same event back off the queue; nil: deliver `e` directly (the caller does).
    static func roundTrip(_ e: NSEvent, mask: NSEvent.EventTypeMask, drop: Bool = false) -> NSEvent? {
        if monitor == nil {
            // A late copy coming out through the app's own run loop (NSApp.sendEvent) is dropped.
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .leftMouseDown, .leftMouseUp, .leftMouseDragged]) {
                ev in
                let type = ev.type, ts = ev.timestamp
                return MainActor.assumeIsolated { isLateCopy(type, ts) } ? nil : ev
            }
        }
        if drop { return nil }  // LMUX_APPTEST_DROP_MOUSE: as if the queue never returned it
        NSApp.postEvent(e, atStart: true)
        if lateCopies {
            // LMUX_APPTEST_LATE_COPY=1: the queue keeps it for later (the old double delivery).
            deliveredDirectly.append((e.type, e.timestamp))
            return nil
        }
        let deadline = Date().addingTimeInterval(0.5)
        repeat {
            guard let ev = NSApp.nextEvent(matching: mask, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true)
            else { continue }
            if same(ev, e) {
                // Its place as made (window coordinates), the rest (current event, monitors) as the queue gave it.
                return ev.locationInWindow == e.locationInWindow ? ev : e
            }
            if !isLateCopy(ev) { NSApp.sendEvent(ev) }  // anything else is dispatched as the app would
        } while Date() < deadline
        deliveredDirectly.append((e.type, e.timestamp))
        return nil
    }
}

@MainActor
func dispatchKey(_ ev: NSEvent, window: NSWindow) {
    let e = SyntheticEvents.roundTrip(ev, mask: [.keyDown, .keyUp]) ?? ev
    if e.type == .keyDown, !e.modifierFlags.isDisjoint(with: [.command, .control]) {
        if window.performKeyEquivalent(with: e) { return }
        if NSApp.mainMenu?.performKeyEquivalent(with: e) == true { return }
    }
    window.sendEvent(e)
}

/// Type plain lowercase text / digits.
@MainActor
func type(_ text: String, window: NSWindow) async {
    for c in text {
        let ts = ProcessInfo.processInfo.systemUptime
        let code: UInt16 = c == "\r" ? 36 : c == "\u{1b}" ? 53 : KC.map[c]!
        let s = String(c)
        for t in [NSEvent.EventType.keyDown, .keyUp] {
            let e = NSEvent.keyEvent(with: t, location: .zero, modifierFlags: [], timestamp: ts,
                                     windowNumber: window.windowNumber, context: nil, characters: s,
                                     charactersIgnoringModifiers: s, isARepeat: false, keyCode: code)!
            dispatchKey(e, window: window)
        }
    }
    await sleepMs(80)
}

/// A shortcut such as ⌘D (`cmd("d")`) or ⇧⌘D (`cmd("d", shift: true)`).
@MainActor
func cmd(_ c: Character, shift: Bool = false, option: Bool = false, window: NSWindow) async {
    var mods: NSEvent.ModifierFlags = [.command]
    if shift { mods.insert(.shift) }
    if option { mods.insert(.option) }
    let ts = ProcessInfo.processInfo.systemUptime
    let s = String(c)
    let chars = shift ? s.uppercased() : s
    for t in [NSEvent.EventType.keyDown, .keyUp] {
        let e = NSEvent.keyEvent(with: t, location: .zero, modifierFlags: mods, timestamp: ts,
                                 windowNumber: window.windowNumber, context: nil, characters: chars,
                                 charactersIgnoringModifiers: chars, isARepeat: false, keyCode: KC.map[c]!)!
        dispatchKey(e, window: window)
    }
    await sleepMs(150)
}

/// Synthesized mouse events the event queue did not return (delivered directly instead).
@MainActor
enum MouseQueue {
    static var misses = 0
    /// LMUX_APPTEST_DROP_MOUSE=1: act as if the queue never returned them (what a sleeping display did).
    static let simulateDrop = ProcessInfo.processInfo.environment["LMUX_APPTEST_DROP_MOUSE"] == "1"
    /// The last click's press duration (mouse-down to mouse-up timestamps), ms.
    static var lastPressMs = 0.0

    /// Display / session state: synthesized clicks used to vanish while the display slept.
    static var environment: String {
        let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        return "display asleep: \(CGDisplayIsAsleep(CGMainDisplayID()) != 0), screen locked: \(locked), screens: \(NSScreen.screens.count)"
            + (SyntheticEvents.droppedLateCopies > 0 ? "; late queued copies dropped: \(SyntheticEvents.droppedLateCopies)" : "")
    }
}

/// Click at a point given in `view`'s coordinates.
@MainActor
func click(_ view: NSView, at p: NSPoint, dragTo: NSPoint? = nil, modifiers: NSEvent.ModifierFlags = []) async {
    guard let window = view.window else { return }
    // What's on screen first: a state change just made (a toggle, a new selection) re-renders
    // SwiftUI on a later runloop turn, and a press landing before that frame went to views being
    // replaced and was dropped now and then. A person can't click inside that frame either.
    window.contentView?.superview?.layoutSubtreeIfNeeded()
    CATransaction.flush()
    await sleepMs(16)
    let start = view.convert(p, to: nil)
    var seq: [(NSEvent.EventType, NSPoint)] = [(.leftMouseDown, start)]
    if let d = dragTo { seq.append((.leftMouseDragged, view.convert(d, to: nil))) }
    seq.append((.leftMouseUp, dragTo.map { view.convert($0, to: nil) } ?? start))
    var downAt = 0.0
    for (type, loc) in seq {
        let e = NSEvent.mouseEvent(with: type, location: loc, modifierFlags: modifiers,
                                   timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                   clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        if type == .leftMouseDown { downAt = e.timestamp } else if type == .leftMouseUp { MouseQueue.lastPressMs = (e.timestamp - downAt) * 1000 }
        if let ev = SyntheticEvents.roundTrip(e, mask: [.leftMouseDown, .leftMouseUp, .leftMouseDragged],
                                              drop: MouseQueue.simulateDrop) {
            window.sendEvent(ev)
        } else {
            // The queue didn't hand our event back (seen with the display asleep / screen
            // locked): route it the way NSApplication would, so the click is never lost silently.
            MouseQueue.misses += 1
            window.sendEvent(e)
        }
        await sleepMs(30)
    }
    await sleepMs(120)
}

/// Pane output sinks: every pane runs `sink.sh`, which writes what the pty
/// receives to <dir>/<LMUX_PANE_ID>.bin.
struct Sinks {
    let dir: URL

    func bytes(_ pane: String) -> [UInt8] {
        Array((try? Data(contentsOf: dir.appendingPathComponent("\(pane).bin"))) ?? Data())
    }

    func ready(_ pane: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(pane).ready").path)
    }

    @MainActor
    func waitReady(_ pane: String, timeout: Double = 5) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if ready(pane) { await sleepMs(150); return true }
            await sleepMs(30)
        }
        return false
    }

    /// Wait until the sink's content contains `needle`.
    @MainActor
    func wait(_ pane: String, contains needle: String, timeout: Double = 3) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if String(decoding: bytes(pane), as: UTF8.self).contains(needle) { return true }
            await sleepMs(30)
        }
        return false
    }

    func text(_ pane: String) -> String {
        String(decoding: bytes(pane), as: UTF8.self).replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}

@MainActor
func waitFor(_ timeout: Double = 3, _ cond: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if cond() { return true }
        await sleepMs(25)
    }
    return cond()
}

/// Run a helper process off the main thread (the app answers its socket on main).
func runProcess(_ path: String, _ args: [String], env: [String: String] = [:], stdin: Data? = nil)
    async -> (status: Int32, out: String, err: String) {
    // On a GCD thread, not the concurrency pool: its blocking reads would hold one of only as many
    // threads as there are cores (3 on a CI runner), and further processes wouldn't start until one ended.
    await withCheckedContinuation { done in
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
            let out = Pipe(), err = Pipe(), inp = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.standardInput = inp
            do { try p.run() } catch { done.resume(returning: (-1, "", "\(error)")); return }
            if let stdin { inp.fileHandleForWriting.write(stdin) }
            try? inp.fileHandleForWriting.close()
            let o = out.fileHandleForReading.readDataToEndOfFile()
            let e = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            done.resume(returning: (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self)))
        }
    }
}
