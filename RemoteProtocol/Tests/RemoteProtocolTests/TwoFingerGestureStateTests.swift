import XCTest
@testable import RemoteProtocol

final class TwoFingerGestureStateTests: XCTestCase {
    func testSmallFingerJitterDoesNotStartZoom() {
        var state = TwoFingerGestureState()
        XCTAssertEqual(state.update(translation: CGPoint(x: 1, y: 3), scale: 1.03), .undecided)
        XCTAssertEqual(state.update(translation: CGPoint(x: 1, y: 9), scale: 1.04), .scroll)
    }

    func testScrollingCannotSwitchToZoomUntilGestureEnds() {
        var state = TwoFingerGestureState()
        XCTAssertEqual(state.update(translation: CGPoint(x: 0, y: 12), scale: 1), .scroll)
        XCTAssertEqual(state.update(translation: CGPoint(x: 0, y: 80), scale: 1.5), .scroll)
        state = TwoFingerGestureState()
        XCTAssertEqual(state.update(translation: .zero, scale: 1.2), .zoom)
    }

    func testPinchingCannotSendTrailingScroll() {
        var state = TwoFingerGestureState()
        XCTAssertEqual(state.update(translation: CGPoint(x: 2, y: 3), scale: 0.85), .zoom)
        XCTAssertEqual(state.update(translation: CGPoint(x: 12, y: 40), scale: 1), .zoom)
    }

    func testInvalidScaleDoesNotChooseIntent() {
        var state = TwoFingerGestureState()
        XCTAssertEqual(state.update(translation: .zero, scale: .nan), .undecided)
        XCTAssertEqual(state.update(translation: .zero, scale: 0), .undecided)
    }
}
