import Foundation

public struct TwoFingerGestureState {
    public enum Intent { case undecided, scroll, zoom }
    public private(set) var intent: Intent = .undecided

    public init() {}

    // Lock the intent until both recognizers finish; finger jitter must not turn scrolling into zoom.
    @discardableResult
    public mutating func update(translation: CGPoint, scale: CGFloat) -> Intent {
        guard intent == .undecided, scale.isFinite, scale > 0,
              translation.x.isFinite, translation.y.isFinite else { return intent }
        if abs(log(scale)) >= 0.10 {
            intent = .zoom
        } else if hypot(translation.x, translation.y) >= 8 {
            intent = .scroll
        }
        return intent
    }
}
