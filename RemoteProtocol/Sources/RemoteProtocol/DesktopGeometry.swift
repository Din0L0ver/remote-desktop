import Foundation
import CoreGraphics

public enum DisplayCutoutSide { case left, right, unknown }

public enum DesktopGeometry {
    // UIKit exposes a rectangular safe area, not the camera's live shape.
    // This conservative iPhone 15 template keeps a 180pt central band protected.
    public static func rowFrame(screen: CGSize, panelOnLeft: Bool, row: Int, count: Int,
                                cutout: DisplayCutoutSide, edgeSafeInset: CGFloat,
                                bottomSafeInset: CGFloat, useIslandTemplate: Bool) -> CGRect {
        let panelWidth = screen.width * 0.16
        let top: CGFloat = 8
        let bottom = max(8, bottomSafeInset + 4)
        let spacing: CGFloat = 5
        let height = max(1, (screen.height - top - bottom - CGFloat(count - 1) * spacing) / CGFloat(max(1, count)))
        let y = top + CGFloat(row) * (height + spacing)
        var outerInset = max(4, edgeSafeInset)
        if useIslandTemplate, cutout != .unknown {
            let radius: CGFloat = 56
            let edgeDistance = min(y, screen.height - y - height)
            let distance = max(0, radius - edgeDistance)
            outerInset = max(6, radius - sqrt(max(0, radius * radius - distance * distance)) + 4)
            let isCutoutSide = (panelOnLeft && cutout == .left) || (!panelOnLeft && cutout == .right)
            if isCutoutSide && y < screen.height / 2 + 90 && y + height > screen.height / 2 - 90 {
                outerInset = max(outerInset, edgeSafeInset + 4)
            }
        }
        return CGRect(x: panelOnLeft ? outerInset : 4, y: y,
                      width: max(1, panelWidth - outerInset - 4), height: height)
    }

    public static func imageRect(image: CGSize, viewport: CGSize, aspectFit: Bool,
                                 zoom: CGFloat, offset: CGPoint) -> CGRect {
        guard image.width > 0, image.height > 0 else { return CGRect(origin: .zero, size: viewport) }
        let sx = viewport.width / image.width
        let sy = viewport.height / image.height
        let scale = (aspectFit ? min(sx, sy) : max(sx, sy)) * max(1, min(4, zoom))
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        let limitX = max(0, (size.width - viewport.width) / 2)
        let limitY = max(0, (size.height - viewport.height) / 2)
        return CGRect(x: (viewport.width - size.width) / 2 + max(-limitX, min(limitX, offset.x)),
                      y: (viewport.height - size.height) / 2 + max(-limitY, min(limitY, offset.y)),
                      width: size.width, height: size.height)
    }
}
