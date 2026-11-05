import Foundation
import LmuxTranscript

// Terminal output across a relaunch: at quit (only then, never periodically) each plain shell pane
// sitting at its prompt saves its last output, as plain text, to <state dir>/scrollback/<pane id>
// (dir 0700, files 0600). The restored pane prints it above its new prompt, then the file is
// deleted. Panes running something (vim, less, a TUI, a build) and agent panes lmux resumes save
// nothing; Settings > General turns it off (then quitting writes nothing and removes what was saved).
// Plain text (libghostty's read_text): its only styled dump, write_screen_file, goes through a temp
// file outside the state dir and formats the whole scrollback.

enum Scrollback {
    static let maxLines = 2_000
    static let maxBytes = 512 * 1024
    static let divider = "\u{1b}[0;2m— restored from your last session —\u{1b}[0m\r\n"

    /// A file name for a pane id (UUIDs; anything else, from an edited layout, has none).
    static func fileName(_ paneID: String) -> String? {
        let ok = !paneID.isEmpty && paneID.count <= 64
            && paneID.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" }
        return ok ? paneID : nil
    }

    /// What may be printed back: text, tabs and newlines. Escape sequences and other control
    /// characters are dropped, so a damaged or edited file can't do more than print odd text.
    static func sanitize(_ s: String) -> String {
        // What lmux saved itself has nothing to drop (0xC2 leads U+0080…U+00BF, C1 included).
        if !s.utf8.contains(where: { ($0 < 0x20 && $0 != 0x0a && $0 != 0x09) || $0 == 0x7f || $0 == 0xc2 }) { return s }
        var out = String.UnicodeScalarView()
        var it = s.unicodeScalars.makeIterator()
        while let c = it.next() {
            switch c.value {
            case 0x0a, 0x09: out.append(c)
            case 0x1b:
                // CSI runs to its final byte; OSC / DCS / APC / PM / SOS to BEL or ST; others are two scalars.
                guard let n = it.next() else { break }
                if n == "[" {
                    while let x = it.next(), !(0x40...0x7e).contains(x.value) {}
                } else if "]P_^X".unicodeScalars.contains(n) {
                    var prev = n
                    while let x = it.next(), !(x.value == 0x07 || (prev.value == 0x1b && x == "\\")) { prev = x }
                }
            case 0x00...0x1f, 0x7f...0x9f: continue
            default: out.append(c)
            }
        }
        return String(out)
    }

    /// The last `maxLines` lines and at most `maxBytes`, trailing blank lines dropped.
    static func trim(_ s: String) -> String {
        var lines = s.split(separator: "\n", omittingEmptySubsequences: false)
        while let last = lines.last, last.allSatisfy({ $0 == " " || $0 == "\t" }) { lines.removeLast() }
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        var bytes = lines.reduce(0) { $0 + $1.utf8.count + 1 }
        while bytes > maxBytes, !lines.isEmpty { bytes -= lines.removeFirst().utf8.count + 1 }
        return lines.joined(separator: "\n")
    }
}

extension LmuxController {
    var scrollbackDir: URL { paths.stateDir.appendingPathComponent("scrollback", isDirectory: true) }

    /// Whether quitting saves this pane's output: not an agent session lmux resumes, and a shell at
    /// its prompt (Ghostty says nothing is running; on the alternate screen it never does).
    func savesScrollback(_ p: Pane) -> Bool {
        if Self.resumeCommand(p.claudeSessionID, saved: p.resumeCommand, agent: p.agentKind) != nil { return false }
        guard Scrollback.fileName(p.id) != nil, !p.surface.needsConfirmQuit,
              let pid = ClaudeProcess.representative(ofGroup: p.surface.foregroundPID),
              let name = ClaudeProcess.name(pid) else { return false }
        return ClaudeProcess.shells.contains(name)
    }

    /// Quit: replace what was saved with every eligible pane's output (nothing when turned off).
    func saveScrollback() {
        guard persistenceEnabled else { return }
        removeSavedScrollback()
        guard settings.restoreScrollback else { return }
        let dir = scrollbackDir
        var made = false
        for p in model.workspaces.flatMap(\.panes) where savesScrollback(p) {
            let text = Scrollback.trim(Scrollback.sanitize(p.surface.screenText(rows: Scrollback.maxLines)))
            guard !text.isEmpty, let name = Scrollback.fileName(p.id) else { continue }
            if !made {
                guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false,
                                                                attributes: [.posixPermissions: 0o700])) != nil,
                      chmod(dir.path, 0o700) == 0 else { return }
                made = true
            }
            do { try PrivateFile.create(dir.appendingPathComponent(name), Data(text.utf8), mode: 0o600) } catch {
                NSLog("lmux: saving terminal output failed: %@", "\(error)")
            }
        }
    }

    /// A restored pane (not resuming an agent): prints what it showed at quit, then a divider.
    func restoreScrollback(savedID: String, into pane: Pane) {
        guard settings.restoreScrollback, let name = Scrollback.fileName(savedID) else { return }
        let url = scrollbackDir.appendingPathComponent(name)
        // Only a small regular file of ours (no link followed); anything else is ignored.
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(),
              st.st_size <= off_t(Scrollback.maxBytes + 4096),
              let data = try? handle.readToEnd(), let raw = String(data: data, encoding: .utf8) else { return }
        unlink(url.path)
        let text = Scrollback.trim(Scrollback.sanitize(raw))
        guard !text.isEmpty else { return }
        let shown = text.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n" + Scrollback.divider
        pane.surface.printOutput(shown)
    }

    /// The saved output, all of it (after a restore: what no pane took; before a save).
    func removeSavedScrollback() {
        try? FileManager.default.removeItem(at: scrollbackDir)
    }
}
