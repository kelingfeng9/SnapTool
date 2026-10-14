import XCTest
import CoreGraphics
@testable import SnapCore

final class ShapeGeometryTests: XCTestCase {
    func testShapeAndToolOrderMatchesVisibleShortcuts() {
        XCTAssertEqual(Array(CaptureShape.allCases.prefix(2)), [.rectangle, .circle])
        XCTAssertEqual(AnnotationTool.allCases, [.rectangle, .ellipse, .arrow, .line, .pen, .text,
                                               .mosaic, .number, .highlight, .select])
    }

    func testShapeMasksIncludeCentersAndExcludeCorners() {
        let rect = CGRect(x: 20, y: 30, width: 100, height: 80)
        for shape in CaptureShape.allCases where shape != .polygon {
            let path = ShapeGeometry.path(shape: shape, in: rect)
            XCTAssertTrue(path.contains(CGPoint(x: 70, y: 70)), "\(shape) should contain its center")
            if shape != .rectangle {
                XCTAssertFalse(path.contains(CGPoint(x: 21, y: 31)), "\(shape) should mask a corner")
            }
        }
        let polygon = ShapeGeometry.path(shape: .polygon, in: rect,
                                          vertices: [CGPoint(x: 20, y: 30), CGPoint(x: 120, y: 30),
                                                     CGPoint(x: 70, y: 110)])
        XCTAssertTrue(polygon.contains(CGPoint(x: 70, y: 60)))
        XCTAssertFalse(polygon.contains(CGPoint(x: 21, y: 100)))
        XCTAssertTrue(ShapeGeometry.path(shape: .polygon, in: rect, vertices: []).isEmpty)
    }

    func testCircleUsesSquareAndRemainsSquareWhileResizingAtEdge() {
        XCTAssertEqual(ShapeGeometry.circleSquare(in: CGRect(x: 10, y: 20, width: 100, height: 60)),
                       CGRect(x: 30, y: 20, width: 60, height: 60))
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let resized = ShapeGeometry.resizeCircle(selection: CGRect(x: 20, y: 20, width: 30, height: 30),
                                                  handle: .bottomRight, to: CGPoint(x: 130, y: 70), within: bounds)
        XCTAssertEqual(resized, CGRect(x: 20, y: 20, width: 80, height: 80))
        let topLeft = ShapeGeometry.resizeCircle(selection: CGRect(x: 20, y: 20, width: 30, height: 30),
                                                  handle: .topLeft, to: CGPoint(x: -20, y: 0), within: bounds)
        XCTAssertEqual(topLeft, CGRect(x: 0, y: 0, width: 50, height: 50))
    }

    func testMoveAndRectangleResizeStayInsideDisplay() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 90)
        let selection = CGRect(x: 20, y: 10, width: 40, height: 30)
        XCTAssertEqual(ShapeGeometry.move(selection: selection, by: CGPoint(x: 100, y: -50), within: bounds),
                       CGRect(x: 60, y: 0, width: 40, height: 30))
        XCTAssertEqual(ShapeGeometry.resize(selection: selection, handle: .bottomRight,
                                              to: CGPoint(x: 150, y: 200), within: bounds),
                       CGRect(x: 20, y: 10, width: 80, height: 80))
    }

    func testEightHandleOrderKeepsExistingCornerIndexes() {
        XCTAssertEqual(SelectionHandle.allCases,
                       [.topLeft, .topRight, .bottomLeft, .bottomRight, .top, .right, .bottom, .left])
    }

    func testRectangleEdgesKeepOppositeEdgeAndIgnoreTangentialMotion() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let selection = CGRect(x: 20, y: 30, width: 40, height: 20)
        XCTAssertEqual(ShapeGeometry.resize(selection: selection, handle: .top,
                                              to: CGPoint(x: 999, y: 5), within: bounds),
                       CGRect(x: 20, y: 5, width: 40, height: 45))
        XCTAssertEqual(ShapeGeometry.resize(selection: selection, handle: .right,
                                              to: CGPoint(x: 90, y: -999), within: bounds),
                       CGRect(x: 20, y: 30, width: 70, height: 20))
        XCTAssertEqual(ShapeGeometry.resize(selection: selection, handle: .bottom,
                                              to: CGPoint(x: -999, y: 110), within: bounds),
                       CGRect(x: 20, y: 30, width: 40, height: 70))
        XCTAssertEqual(ShapeGeometry.resize(selection: selection, handle: .left,
                                              to: CGPoint(x: -5, y: 999), within: bounds),
                       CGRect(x: 0, y: 30, width: 60, height: 20))
        let crossed = ShapeGeometry.resize(selection: selection, handle: .top,
                                            to: CGPoint(x: 0, y: 80), within: bounds)
        XCTAssertEqual(crossed, CGRect(x: 20, y: 50, width: 40, height: 30))
    }

    func testCircleEdgeResizeFixesOppositeMidpointAndAllowsShrinking() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let selection = CGRect(x: 30, y: 30, width: 40, height: 40)
        let top = ShapeGeometry.resize(selection: selection, handle: .top,
                                         to: CGPoint(x: 200, y: 10), within: bounds, square: true)
        XCTAssertEqual(top, CGRect(x: 20, y: 10, width: 60, height: 60))
        XCTAssertEqual(CGPoint(x: top.midX, y: top.maxY), CGPoint(x: selection.midX, y: selection.maxY))
        let right = ShapeGeometry.resizeCircle(selection: selection, handle: .right,
                                                to: CGPoint(x: 110, y: -100), within: bounds)
        XCTAssertEqual(right, CGRect(x: 30, y: 15, width: 70, height: 70))
        XCTAssertEqual(CGPoint(x: right.minX, y: right.midY), CGPoint(x: selection.minX, y: selection.midY))
        let bottom = ShapeGeometry.resizeCircle(selection: selection, handle: .bottom,
                                                 to: CGPoint(x: 0, y: 60), within: bounds)
        XCTAssertEqual(bottom, CGRect(x: 35, y: 30, width: 30, height: 30))
        XCTAssertEqual(CGPoint(x: bottom.midX, y: bottom.minY), CGPoint(x: selection.midX, y: selection.minY))
        let left = ShapeGeometry.resizeCircle(selection: selection, handle: .left,
                                               to: CGPoint(x: 45, y: 1000), within: bounds)
        XCTAssertEqual(left, CGRect(x: 45, y: 37.5, width: 25, height: 25))
        XCTAssertEqual(CGPoint(x: left.maxX, y: left.midY), CGPoint(x: selection.maxX, y: selection.midY))
    }

    func testCircleEdgesRespectPerpendicularBoundsAndNeverInvert() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let nearLeft = CGRect(x: 5, y: 20, width: 20, height: 20)
        XCTAssertEqual(ShapeGeometry.resizeCircle(selection: nearLeft, handle: .top,
                                                    to: CGPoint(x: 15, y: -100), within: bounds),
                       CGRect(x: 0, y: 10, width: 30, height: 30))
        let nearTop = CGRect(x: 20, y: 5, width: 20, height: 20)
        XCTAssertEqual(ShapeGeometry.resizeCircle(selection: nearTop, handle: .right,
                                                    to: CGPoint(x: 200, y: 15), within: bounds),
                       CGRect(x: 20, y: 0, width: 30, height: 30))
        let selection = CGRect(x: 30, y: 30, width: 40, height: 40)
        let crossedTop = ShapeGeometry.resizeCircle(selection: selection, handle: .top,
                                                       to: CGPoint(x: 0, y: 80), within: bounds)
        XCTAssertEqual(crossedTop, CGRect(x: 50, y: 70, width: 0, height: 0))
        let crossedRight = ShapeGeometry.resizeCircle(selection: selection, handle: .right,
                                                         to: CGPoint(x: 20, y: 0), within: bounds)
        XCTAssertEqual(crossedRight, CGRect(x: 30, y: 50, width: 0, height: 0))
    }

    func testShiftConstraintsPreserveLineLengthAndSnapDirection() {
        let start = CGPoint(x: 50, y: 50), end = CGPoint(x: 12, y: 30)
        let square = ShapeGeometry.constrainedEnd(start: start, end: end, tool: .ellipse, enabled: true)
        XCTAssertEqual(square, CGPoint(x: 12, y: 12))
        let line = ShapeGeometry.constrainedEnd(start: .zero, end: CGPoint(x: 10, y: 3), tool: .line, enabled: true)
        XCTAssertEqual(line.y, 0, accuracy: 0.00001)
        XCTAssertEqual(line.x, hypot(10, 3), accuracy: 0.00001)
        XCTAssertEqual(ShapeGeometry.constrainedEnd(start: start, end: end, tool: .pen, enabled: true), end)
        let circle = ShapeGeometry.constrainedCaptureEnd(start: .zero, end: CGPoint(x: 30, y: 15), shape: .circle)
        XCTAssertEqual(circle, CGPoint(x: 30, y: 30))
    }

    func testOutlineHitTestingDoesNotSelectInteriorUntilFilled() {
        var rectangle = Annotation(tool: .rectangle, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 80, y: 60))
        XCTAssertTrue(AnnotationGeometry.hitTest(CGPoint(x: 11, y: 30), annotation: rectangle))
        XCTAssertFalse(AnnotationGeometry.hitTest(CGPoint(x: 45, y: 35), annotation: rectangle))
        rectangle.filled = true
        XCTAssertTrue(AnnotationGeometry.hitTest(CGPoint(x: 45, y: 35), annotation: rectangle))
        var ellipse = Annotation(tool: .ellipse, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 90, y: 70))
        XCTAssertTrue(AnnotationGeometry.hitTest(CGPoint(x: 90, y: 40), annotation: ellipse))
        XCTAssertFalse(AnnotationGeometry.hitTest(CGPoint(x: 50, y: 40), annotation: ellipse))
        ellipse.filled = true
        XCTAssertTrue(AnnotationGeometry.hitTest(CGPoint(x: 50, y: 40), annotation: ellipse))
        XCTAssertFalse(AnnotationGeometry.hitTest(CGPoint(x: 11, y: 11), annotation: ellipse))
    }

    func testTopmostAndPenHitTesting() {
        let lower = Annotation(tool: .rectangle, start: .zero, end: CGPoint(x: 80, y: 80), filled: true)
        let upper = Annotation(tool: .line, start: CGPoint(x: 5, y: 30), end: CGPoint(x: 70, y: 30))
        XCTAssertEqual(AnnotationGeometry.hitTest(CGPoint(x: 40, y: 30), annotations: [lower, upper]), upper.id)
        let pen = Annotation(tool: .pen, start: .zero, end: CGPoint(x: 50, y: 50),
                             points: [.zero, CGPoint(x: 50, y: 0), CGPoint(x: 50, y: 50)])
        XCTAssertTrue(AnnotationGeometry.hitTest(CGPoint(x: 49, y: 30), annotation: pen))
        XCTAssertFalse(AnnotationGeometry.hitTest(CGPoint(x: 25, y: 25), annotation: pen))
    }
}
