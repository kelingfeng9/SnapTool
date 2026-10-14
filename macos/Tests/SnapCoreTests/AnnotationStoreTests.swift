import XCTest
import CoreGraphics
@testable import SnapCore

final class AnnotationStoreTests: XCTestCase {
    func testUndoRedoDeleteRestoresOriginalOrder() {
        let store = AnnotationStore()
        let first = Annotation(tool: .rectangle, start: .zero, end: CGPoint(x: 20, y: 20))
        let second = Annotation(tool: .ellipse, start: .zero, end: CGPoint(x: 30, y: 30))
        store.add(first); store.add(second); store.remove(id: first.id)
        XCTAssertEqual(store.items.map(\.id), [second.id])
        XCTAssertTrue(store.undo())
        XCTAssertEqual(store.items.map(\.id), [first.id, second.id])
        XCTAssertTrue(store.redo())
        XCTAssertEqual(store.items.map(\.id), [second.id])
        XCTAssertTrue(store.undo()); XCTAssertTrue(store.undo()); XCTAssertTrue(store.undo())
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(store.undo())
        XCTAssertTrue(store.redo()); XCTAssertTrue(store.redo())
        XCTAssertEqual(store.items, [first, second])
    }

    func testNewBranchClearsRedoButNoOpDoesNot() {
        let store = AnnotationStore()
        let item = Annotation(tool: .line, start: .zero, end: CGPoint(x: 20, y: 20))
        store.add(item); store.move(id: item.id, delta: CGPoint(x: 10, y: 0)); store.undo()
        XCTAssertTrue(store.canRedo)
        store.move(id: item.id, delta: .zero); store.replace(item)
        XCTAssertTrue(store.canRedo)
        store.updateStyle(id: item.id, width: 8)
        XCTAssertFalse(store.canRedo)
        XCTAssertFalse(store.redo())
        XCTAssertEqual(store.items[0].width, 8)
        store.undo(); XCTAssertEqual(store.items[0], item)
    }

    func testMoveTranslatesAllPenPointsAndStyleUndoKeepsPosition() {
        let store = AnnotationStore()
        let pen = Annotation(tool: .pen, start: CGPoint(x: 1, y: 2), end: CGPoint(x: 5, y: 6),
                             points: [CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4), CGPoint(x: 5, y: 6)])
        store.add(pen); store.move(id: pen.id, delta: CGPoint(x: 20, y: -1))
        let moved = store.items[0]
        XCTAssertEqual(moved.start, CGPoint(x: 21, y: 1))
        XCTAssertEqual(moved.end, CGPoint(x: 25, y: 5))
        XCTAssertEqual(moved.points[1], CGPoint(x: 23, y: 3))
        store.updateStyle(id: pen.id, color: .black, width: 10, fontSize: 32, filled: true, doubleArrow: true)
        XCTAssertEqual(store.items[0].color, .black)
        store.undo(); XCTAssertEqual(store.items[0], moved)
        store.undo(); XCTAssertEqual(store.items[0], pen)
        store.redo(); XCTAssertEqual(store.items[0], moved)
    }

    func testReplaceIncludesMosaicSettingsAndClearReleasesHistory() {
        let store = AnnotationStore()
        var item = Annotation(tool: .mosaic, start: .zero, end: CGPoint(x: 50, y: 50), blockSize: 12)
        store.add(item); item.blockSize = 24; store.replace(item)
        XCTAssertEqual(store.items[0].blockSize, 24)
        store.undo(); XCTAssertEqual(store.items[0].blockSize, 12)
        store.clear()
        XCTAssertTrue(store.items.isEmpty); XCTAssertFalse(store.canUndo); XCTAssertFalse(store.canRedo)
    }

    func testDuplicateIdentityDoesNotCorruptHistory() {
        let store = AnnotationStore()
        let item = Annotation(tool: .text, start: .zero, end: .zero, text: "文字")
        store.add(item); store.add(item)
        XCTAssertEqual(store.items.count, 1)
        store.undo(); XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(store.undo())
    }
}
