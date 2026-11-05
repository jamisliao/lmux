import AppKit
import Carbon
import GhosttyKit
import LmuxTerminal
import LmuxTokens

private typealias T = LmuxTokens

// ⌘F scrollback search and Secure Keyboard Entry, both done by libghostty; lmux only adds
// a small find bar (AppKit, top right of the pane) and a menu toggle.
//
// Search: Ghostty's `start_search` (⌘F) opens the bar, typing sends `search:<text>`,
// Return / ⌘G = `navigate_search:next`, ⇧Return / ⇧⌘G = previous, Esc = `end_search`.
// libghostty highlights the matches and reports the total and the selected match.

/// The find bar: text field, "3/12", previous / next, close.
final class FindBar: PanelView, NSTextFieldDelegate {
    let field = NSTextField()
    let count = NSTextField(labelWithString: "")
    let prev: OverlayButton
    let next: OverlayButton
    let close: OverlayButton
    var onChange: ((String) -> Void)?
    var onNavigate: ((Bool) -> Void)?  // true = next
    var onClose: (() -> Void)?
    var total: Int? { didSet { updateCount() } }
    var selected: Int? { didSet { updateCount() } }

    static let size = NSSize(width: 300, height: 34)

    override init(frame: NSRect) {
        prev = OverlayButton(symbol: "chevron.up", style: .icon, help: "Previous match (⇧⌘G)")
        next = OverlayButton(symbol: "chevron.down", style: .icon, help: "Next match (⌘G)")
        close = OverlayButton(symbol: "xmark", style: .icon, help: "Close (esc)")
        super.init(frame: frame)
        field.placeholderString = "Find"
        field.font = .systemFont(ofSize: 12.5)
        field.focusRingType = .none
        field.isBordered = false
        field.drawsBackground = false
        field.textColor = T.Colors.textPrimary.nsColor
        field.delegate = self
        field.cell?.isScrollable = true
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.textColor = T.Colors.textTertiary.nsColor
        count.alignment = .right
        prev.action = { [weak self] in self?.onNavigate?(false) }
        next.action = { [weak self] in self?.onNavigate?(true) }
        close.action = { [weak self] in self?.onClose?() }
        for v in [field, count, prev, next, close] as [NSView] { addSubview(v) }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func updateCount() {
        guard let total else { count.stringValue = ""; return }
        count.stringValue = total == 0 ? "0" : "\(selected.map { String($0 + 1) } ?? "–")/\(total)"
    }

    override func layout() {
        super.layout()
        let s = T.Layout.hoverActionSize, y = (bounds.height - s) / 2
        close.frame = NSRect(x: bounds.width - 6 - s, y: y, width: s, height: s)
        next.frame = NSRect(x: close.frame.minX - 2 - s, y: y, width: s, height: s)
        prev.frame = NSRect(x: next.frame.minX - 2 - s, y: y, width: s, height: s)
        count.frame = NSRect(x: prev.frame.minX - 56, y: (bounds.height - 16) / 2, width: 52, height: 16)
        field.frame = NSRect(x: 12, y: (bounds.height - 18) / 2, width: count.frame.minX - 16, height: 18)
    }

    func controlTextDidChange(_ obj: Notification) { onChange?(field.stringValue) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)):
            onNavigate?(!(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false))
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}

extension LmuxController {
    // MARK: - Search

    /// libghostty started a search in `pane` (⌘F, or `search_selection` with a needle).
    func searchStarted(_ pane: Pane, needle: String?) {
        let ov = pane.view.overlay
        if ov.findBar == nil {
            let bar = FindBar(frame: .zero)
            bar.onChange = { [weak pane] text in
                guard pane?.surface.inputHeld != true else { return }
                _ = pane?.surface.performBindingAction("search:" + text)
            }
            bar.onNavigate = { [weak pane] forward in
                guard pane?.surface.inputHeld != true else { return }
                _ = pane?.surface.performBindingAction("navigate_search:" + (forward ? "next" : "previous"))
            }
            bar.onClose = { [weak self, weak pane] in
                guard let self, let pane else { return }
                _ = pane.surface.performBindingAction("end_search")
                self.searchEnded(pane)
            }
            ov.addSubview(bar)
            ov.findBar = bar
            ov.needsLayout = true
        }
        let bar = ov.findBar!
        if let needle, !needle.isEmpty, bar.field.stringValue != needle { bar.field.stringValue = needle }
        window.makeFirstResponder(bar.field)
        bar.field.currentEditor()?.selectAll(nil)
    }

    func searchEnded(_ pane: Pane) {
        let ov = pane.view.overlay
        guard let bar = ov.findBar else { return }
        bar.removeFromSuperview()
        ov.findBar = nil
        if pane.workspace === model.selected, pane.workspace?.focusedPane === pane { window.makeFirstResponder(pane.surface) }
    }

    func searchCounts(_ pane: Pane, total: Int?, selected: Int?) {
        guard let bar = pane.view.overlay.findBar else { return }
        if let total { bar.total = total }
        bar.selected = selected
    }

    @objc func menuFind(_ sender: Any?) {
        // A find scrolls the viewport lmux is reading to drive Claude's rewind.
        guard let p = model.selected?.focusedPane, !p.surface.inputHeld else { return }
        if !p.surface.performBindingAction("start_search") { searchStarted(p, needle: nil) }
    }

    @objc func menuFindNext(_ sender: Any?) {
        guard let s = model.selected?.focusedPane?.surface, !s.inputHeld else { return }
        _ = s.performBindingAction("navigate_search:next")
    }
    @objc func menuFindPrevious(_ sender: Any?) {
        guard let s = model.selected?.focusedPane?.surface, !s.inputHeld else { return }
        _ = s.performBindingAction("navigate_search:previous")
    }

    // MARK: - Secure Keyboard Entry

    /// While on and lmux is the active app, macOS keeps other apps from reading keystrokes.
    public var secureKeyboardEntry: Bool {
        get { secureInputWanted }
        set {
            secureInputWanted = newValue
            if !headless { UserDefaults.standard.set(newValue, forKey: "secureKeyboardEntry") }
            applySecureInput()
            secureInputMenuItem?.state = newValue ? .on : .off
        }
    }

    /// Engage or release the system's secure input to match the setting and app activity.
    func applySecureInput() {
        let want = secureInputWanted && NSApp.isActive
        if want && !secureInputEngaged {
            EnableSecureEventInput()
            secureInputEngaged = true
        } else if !want && secureInputEngaged {
            DisableSecureEventInput()
            secureInputEngaged = false
        }
    }

    @objc func menuToggleSecureInput(_ sender: Any?) { secureKeyboardEntry.toggle() }
}
