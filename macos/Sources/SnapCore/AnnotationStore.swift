import Foundation
import CoreGraphics

/// A small command history. Changes retain only the affected annotation; they
/// never duplicate the captured desktop image.
public final class AnnotationStore {
    public private(set) var items: [Annotation] = []
    private struct Change {
        var before: Annotation?
        var after: Annotation?
        var index: Int
    }
    private var past: [Change] = []
    private var future: [Change] = []
    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }

    public init() {}

    public func add(_ annotation: Annotation) {
        guard !items.contains(where: { $0.id == annotation.id }) else { return }
        let change = Change(before: nil, after: annotation, index: items.count)
        items.append(annotation); record(change)
    }

    public func remove(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let old = items.remove(at: index)
        record(Change(before: old, after: nil, index: index))
    }

    public func move(id: UUID, delta: CGPoint) {
        guard delta.x != 0 || delta.y != 0,
              let old = items.first(where: { $0.id == id }) else { return }
        replace(old.translated(by: delta))
    }

    public func replace(_ annotation: Annotation) {
        guard let index = items.firstIndex(where: { $0.id == annotation.id }),
              items[index] != annotation else { return }
        let old = items[index]; items[index] = annotation
        record(Change(before: old, after: annotation, index: index))
    }

    public func updateStyle(id: UUID, color: RGBAColor? = nil, width: CGFloat? = nil,
                            fontSize: CGFloat? = nil, filled: Bool? = nil, doubleArrow: Bool? = nil) {
        guard var annotation = items.first(where: { $0.id == id }) else { return }
        if let color { annotation.color = color }
        if let width, width.isFinite { annotation.width = max(1, min(width, 100)) }
        if let fontSize, fontSize.isFinite { annotation.fontSize = max(8, min(fontSize, 200)) }
        if let filled { annotation.filled = filled }
        if let doubleArrow { annotation.doubleArrow = doubleArrow }
        replace(annotation)
    }

    @discardableResult public func undo() -> Bool {
        guard let change = past.popLast() else { return false }
        replay(change, forward: false); future.append(change); return true
    }

    @discardableResult public func redo() -> Bool {
        guard let change = future.popLast() else { return false }
        replay(change, forward: true); past.append(change); return true
    }

    public func clear() { items.removeAll(); past.removeAll(); future.removeAll() }

    private func record(_ change: Change) { past.append(change); future.removeAll() }

    private func replay(_ change: Change, forward: Bool) {
        let current = forward ? change.before : change.after
        let replacement = forward ? change.after : change.before
        if let id = (current ?? replacement)?.id,
           let index = items.firstIndex(where: { $0.id == id }) {
            if let replacement { items[index] = replacement }
            else { items.remove(at: index) }
        } else if let replacement {
            items.insert(replacement, at: min(change.index, items.count))
        }
    }
}
