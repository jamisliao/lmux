import AppKit
import LmuxTokens
import SwiftUI

private typealias T = LmuxTokens

// Sidebar reordering: press-and-drag (Sidebar.swift's WorkspaceRow owns the gesture and
// SidebarRowMotion the rows' lift and slide; this file is the model side and the drag geometry)
// and VoiceOver's Move Up / Down. Dragging a row that's part of the current multi-selection moves
// the whole selection, keeping their relative order (`closeTargets`, like ×). The order lives in
// `model.workspaces` itself, so it's part of the saved layout (`scheduleSave`) and ⌘1-⌘8 follow
// it without anything extra.

extension LmuxController {
    /// Move `targets` to position `index` among the workspaces not in `targets`, keeping their
    /// relative order. Shared by Move Up / Down and drag-and-drop.
    private func reorderWorkspaces(_ targets: [Workspace], toRestIndex index: Int) {
        guard !targets.isEmpty else { return }
        let ids = Set(targets.map(\.id))
        let moving = model.workspaces.filter { ids.contains($0.id) }  // keeps relative order
        guard !moving.isEmpty else { return }
        var result = model.workspaces.filter { !ids.contains($0.id) }
        result.insert(contentsOf: moving, at: min(max(index, 0), result.count))
        model.workspaces = result
        scheduleSave()
    }

    /// VoiceOver "Move Up" / "Move Down": one position earlier / later among the rows outside
    /// the selection.
    public func moveWorkspace(from ws: Workspace, by delta: Int) {
        let moving = closeTargets(for: ws)
        guard let firstIndex = model.workspaces.firstIndex(where: { w in moving.contains { $0 === w } }) else { return }
        let ids = Set(moving.map(\.id))
        let before = model.workspaces[..<firstIndex].filter { !ids.contains($0.id) }.count
        reorderWorkspaces(moving, toRestIndex: before + delta)
    }

    // MARK: - Drag and drop

    /// A row press-dragged past the click threshold (Sidebar.swift's `WorkspaceRow`), or an
    /// update while it continues: `index` is how many of the other rows the dragged ones would
    /// land below, `translation` how far the pointer has moved since the press (the lifted rows
    /// follow it). Only a new slot touches `sidebarDrag` (the other rows slide, animated); a move
    /// within the slot updates `sidebarDragPointer` alone.
    public func sidebarDragUpdate(_ ws: Workspace, dropIndex index: Int, pointerY: CGFloat, translation: CGFloat = 0) {
        guard !sidebarDragCancelled else { return }  // Esc ended this gesture's drag for good
        var drag = model.sidebarDrag
        if drag == nil {
            let moving = closeTargets(for: ws)
            guard !moving.isEmpty else { return }
            drag = AppModel.SidebarDrag(ids: moving.map(\.id), grabbedID: ws.id, dropIndex: 0)
        }
        guard var next = drag else { return }
        let rest = model.workspaces.filter { !Set(next.ids).contains($0.id) }
        next.dropIndex = min(max(index, 0), rest.count)
        if next != model.sidebarDrag { withAnimation(reorderAnimation) { model.sidebarDrag = next } }
        model.sidebarDragPointer = AppModel.SidebarDragPointer(y: pointerY, translation: translation)
    }

    /// Mouse up: commit the move where it was last pointing; the dropped rows settle into their
    /// slot from under the pointer (the others are already where the new order puts them).
    public func sidebarDragEnded() {
        guard let drag = model.sidebarDrag else { return }
        let ids = Set(drag.ids)
        let targets = model.workspaces.filter { ids.contains($0.id) }
        withAnimation(reorderAnimation) {
            model.sidebarDrag = nil
            model.sidebarDragPointer = nil
            reorderWorkspaces(targets, toRestIndex: drag.dropIndex)
        }
    }

    /// Esc: spring it back where it started (and keep it dropped until the next press).
    public func cancelSidebarDrag() {
        withAnimation(reorderAnimation) {
            model.sidebarDrag = nil
            model.sidebarDragPointer = nil
        }
        sidebarDragCancelled = true
    }

    /// Reduce Motion: rows jump instead of sliding (the lifted ones still follow the pointer).
    private var reorderAnimation: Animation? { T.Motion.reduceMotion ? nil : T.Motion.reorder }

    /// Near the top or bottom of the visible rows while dragging, nudge the list toward that end
    /// (only while a drag is in progress: no polling otherwise).
    public func sidebarAutoScroll(proxy: ScrollViewProxy, viewportHeight: CGFloat) {
        guard let pointer = model.sidebarDragPointer, viewportHeight > 0 else { return }
        let margin: CGFloat = 28
        if pointer.y < margin, let first = model.workspaces.first {
            proxy.scrollTo(first.id, anchor: .top)
        } else if pointer.y > viewportHeight - margin, let last = model.workspaces.last {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }
}

/// The rows' geometry during a drag, from their laid-out frames (`sidebarRowsSpace`, drag offsets
/// not included): which slot the dragged rows are over, and how far each row is shifted to show
/// it. The rows being dragged travel as one block (a multi-selection closes up behind the grabbed
/// row) that follows the pointer; the others make room for it at the drop slot.
struct SidebarDragGeometry {
    let order: [String]
    let moving: Set<String>
    let frames: [String: CGRect]
    var gap: CGFloat = T.Layout.rowGap

    private var rest: [String] { order.filter { !moving.contains($0) } }
    private var block: [String] { order.filter { moving.contains($0) } }
    private func step(_ id: String) -> CGFloat { (frames[id]?.height ?? 0) + gap }
    private var top: CGFloat { order.compactMap { frames[$0]?.minY }.min() ?? 0 }

    /// Where `id` sits inside the block (its distance from the block's top).
    private func blockOffset(_ id: String) -> CGFloat {
        var y: CGFloat = 0
        for b in block { if b == id { break }; y += step(b) }
        return y
    }

    /// The slot (`0...rest.count`) whose top is nearest the dragged block's top: a neighbor makes
    /// room once the block has moved halfway over it.
    func dropIndex(grabbed: String, translation: CGFloat) -> Int {
        guard let f = frames[grabbed] else { return 0 }
        let blockTop = f.minY + translation - blockOffset(grabbed)
        var y = top, d = 0
        for id in rest {
            guard blockTop > y + step(id) / 2 else { break }
            y += step(id)
            d += 1
        }
        return d
    }

    /// Each row's vertical shift with the block at `dropIndex` (the lifted rows' before the live
    /// pointer translation is added).
    func offsets(grabbed: String, dropIndex: Int) -> [String: CGFloat] {
        var out: [String: CGFloat] = [:]
        let extent = block.reduce(0) { $0 + step($1) }
        var y = top
        for (k, id) in rest.enumerated() {
            if k == dropIndex { y += extent }
            if let f = frames[id] { out[id] = y - f.minY }
            y += step(id)
        }
        if let g = frames[grabbed] {
            for id in block {
                guard let f = frames[id] else { continue }
                out[id] = blockOffset(id) - blockOffset(grabbed) - (f.minY - g.minY)
            }
        }
        return out
    }
}
