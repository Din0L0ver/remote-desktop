import XCTest
import CoreGraphics
@testable import MacHost

final class RemoteInputTests: XCTestCase {
    private var events: [CGEvent] = []
    private func controller() -> RemoteInputController {
        RemoteInputController(emit: { [weak self] in self?.events.append($0) },
                              displayBounds: { CGRect(x: 20, y: 10, width: 1440, height: 900) })
    }

    func testShortcutReleaseDoesNotLeaveCommandOrShiftSet() {
        let input = controller()
        for command in ["copy", "paste", "cut", "selectAll", "undo", "redo", "zoomIn", "zoomOut", "actualSize"] {
            events.removeAll()
            input.handle(["type": "shortcut", "value": command])
            XCTAssertTrue(events[0].flags.contains(.maskCommand), command)
            XCTAssertEqual(events[1].type, .keyUp)
            XCTAssertEqual(events[1].flags.rawValue, 0, "\(command) must release its modifiers")
        }
    }

    func testCopyThenDockClickScrollAndTypingHaveNoModifiers() {
        let input = controller()
        input.handle(["type": "shortcut", "value": "copy"])
        input.handle(["type": "mouse", "action": "click", "x": 0.5, "y": 0.95])
        input.handle(["type": "scroll", "dy": 18.0])
        input.handle(["type": "text", "value": "x"])
        input.handle(["type": "key", "value": "return"])
        XCTAssertEqual(events.map(\.type), [.keyDown, .keyUp, .leftMouseDown, .leftMouseUp, .scrollWheel, .keyDown, .keyUp, .keyDown, .keyUp])
        for event in events.dropFirst() { XCTAssertEqual(event.flags.rawValue, 0) }
    }

    func testDragProducesDownDraggedUpAndClampsToDisplayPoints() {
        let input = controller()
        input.handle(["type": "mouse", "action": "down", "x": 0.25, "y": 0.25])
        input.handle(["type": "mouse", "action": "drag", "x": 2.0, "y": -1.0])
        input.handle(["type": "release"])
        input.handle(["type": "release"])
        XCTAssertEqual(events.map(\.type), [.leftMouseDown, .leftMouseDragged, .leftMouseUp])
        XCTAssertEqual(events[1].location, CGPoint(x: 1459, y: 10))
        XCTAssertFalse(input.isDragging)
    }

    func testHoldDoesNotRepeatDownAndExpiryReleases() {
        let input = controller()
        for _ in 0..<2 { input.handle(["type": "mouse", "action": "down", "x": 0.5, "y": 0.5]) }
        input.handle(["type": "hold"])
        input.releaseIfExpired()
        XCTAssertEqual(events.map(\.type), [.leftMouseDown])
        input.releaseIfExpired(now: ProcessInfo.processInfo.systemUptime + 9)
        XCTAssertEqual(events.map(\.type), [.leftMouseDown, .leftMouseUp])
    }

    func testDisconnectReleaseThenNormalMove() {
        let input = controller()
        input.handle(["type": "mouse", "action": "down", "x": 0.0, "y": 0.0])
        input.release()
        input.handle(["type": "mouse", "action": "move", "x": 0.5, "y": 0.5])
        XCTAssertEqual(events.map(\.type), [.leftMouseDown, .leftMouseUp, .mouseMoved])
    }

    func testCopyReleasesSelectionAndUsesCommandC() {
        let input = controller()
        input.handle(["type": "mouse", "action": "down", "x": 0.0, "y": 0.0])
        input.handle(["type": "shortcut", "value": "copy"])
        XCTAssertEqual(events.map(\.type), [.leftMouseDown, .leftMouseUp, .keyDown, .keyUp])
        XCTAssertEqual(events[2].getIntegerValueField(.keyboardEventKeycode), 8)
        XCTAssertTrue(events[2].flags.contains(.maskCommand))
        XCTAssertFalse(input.isDragging)
    }

    func testPasteSelectAllAndRedoModifiers() {
        let input = controller()
        for value in ["paste", "selectAll", "redo"] { input.handle(["type": "shortcut", "value": value]) }
        XCTAssertEqual(events.filter { $0.type == .keyDown }.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [9, 0, 6])
        XCTAssertTrue(events[4].flags.contains([.maskCommand, .maskShift]))
    }

    func testDoubleClickCountsAndContextClick() {
        let input = controller()
        input.handle(["type": "mouse", "action": "doubleClick", "x": 0.5, "y": 0.5])
        XCTAssertEqual(events.map { $0.getIntegerValueField(.mouseEventClickState) }, [1, 1, 2, 2])
        input.handle(["type": "mouse", "action": "rightClick", "x": 0.5, "y": 0.5])
        XCTAssertEqual(Array(events.suffix(2)).map(\.type), [.rightMouseDown, .rightMouseUp])
    }

    func testInvalidCoordinatesDoNotGenerateMouseEvents() {
        let input = controller()
        input.handle(["type": "mouse", "action": "down", "x": Double.nan, "y": 0.5])
        input.handle(["type": "mouse", "action": "down", "x": 0.5])
        XCTAssertTrue(events.isEmpty)
    }

    func testClickAfterSelectionReleasesThenActuallyClicks() {
        let input = controller()
        input.handle(["type": "mouse", "action": "down", "x": 0.1, "y": 0.1])
        input.handle(["type": "mouse", "action": "drag", "x": 0.3, "y": 0.3])
        input.handle(["type": "mouse", "action": "click", "x": 0.7, "y": 0.7])
        XCTAssertEqual(events.map(\.type), [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .leftMouseDown, .leftMouseUp])
        XCTAssertEqual(events[2].location, events[1].location)
        XCTAssertFalse(input.isDragging)
    }

    func testScrollAfterSelectionReleasesBeforeScrolling() {
        let input = controller()
        input.handle(["type": "mouse", "action": "down", "x": 0.1, "y": 0.1])
        input.handle(["type": "scroll", "dy": 18.0])
        input.handle(["type": "hold"])
        input.handle(["type": "mouse", "action": "move", "x": 0.2, "y": 0.2])
        XCTAssertEqual(events.map(\.type), [.leftMouseDown, .leftMouseUp, .scrollWheel, .mouseMoved])
        XCTAssertEqual(events[2].getIntegerValueField(.scrollWheelEventDeltaAxis1), 3)
        XCTAssertFalse(input.isDragging)
    }

    func testPlainMoveCancelsStaleHoldAtPreviousPosition() {
        let input = controller()
        input.handle(["type": "mouse", "action": "down", "x": 0.1, "y": 0.1])
        input.handle(["type": "mouse", "action": "move", "x": 0.9, "y": 0.9])
        XCTAssertEqual(events.map(\.type), [.leftMouseDown, .leftMouseUp, .mouseMoved])
        XCTAssertEqual(events[0].location, events[1].location)
        XCTAssertFalse(input.isDragging)
    }

    func testTypingAndReturnEndHold() {
        let input = controller()
        for payload: [String: Any] in [["type": "text", "value": "a"], ["type": "key", "value": "return"]] {
            events.removeAll()
            input.handle(["type": "mouse", "action": "down", "x": 0.1, "y": 0.1])
            input.handle(payload)
            XCTAssertEqual(events.map(\.type), [.leftMouseDown, .leftMouseUp, .keyDown, .keyUp])
            XCTAssertFalse(input.isDragging)
        }
    }
}
