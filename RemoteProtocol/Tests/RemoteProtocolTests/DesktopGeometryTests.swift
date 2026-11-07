import XCTest
@testable import RemoteProtocol

final class DesktopGeometryTests: XCTestCase {
    let screen = CGSize(width: 852, height: 393)

    func testRowsNeverEnterDesktopOrIslandProtectedArea() {
        for cutout in [DisplayCutoutSide.left, .right] {
            for left in [true, false] {
                for count in [5, 8, 9, 10] {
                    var previousMaxY: CGFloat = 0
                    for index in 0..<count {
                        let row = DesktopGeometry.rowFrame(screen: screen, panelOnLeft: left, row: index, count: count,
                                                           cutout: cutout, edgeSafeInset: 59, bottomSafeInset: 21, useIslandTemplate: true)
                        XCTAssertGreaterThan(row.width, 0)
                        XCTAssertGreaterThan(row.minY, previousMaxY)
                        XCTAssertGreaterThanOrEqual(row.minX, 4)
                        XCTAssertLessThanOrEqual(row.maxX, screen.width * 0.16 - 4)
                        XCTAssertLessThanOrEqual(row.maxY, screen.height - 25)
                        let islandSide = (left && cutout == .left) || (!left && cutout == .right)
                        if islandSide && row.minY < screen.height / 2 + 90 && row.maxY > screen.height / 2 - 90 {
                            if left { XCTAssertGreaterThanOrEqual(row.minX, 63) }
                            else { XCTAssertLessThanOrEqual(row.maxX, screen.width * 0.16 - 63) }
                        }
                        previousMaxY = row.maxY
                    }
                }
            }
        }
    }

    func testFreeSideUsesMoreWidthAndUnknownDevicesKeepSafeArea() {
        let free = DesktopGeometry.rowFrame(screen: screen, panelOnLeft: true, row: 4, count: 9,
                                            cutout: .right, edgeSafeInset: 59, bottomSafeInset: 21, useIslandTemplate: true)
        let safe = DesktopGeometry.rowFrame(screen: screen, panelOnLeft: true, row: 4, count: 9,
                                            cutout: .unknown, edgeSafeInset: 59, bottomSafeInset: 21, useIslandTemplate: true)
        XCTAssertGreaterThan(free.width, safe.width + 40)
        XCTAssertEqual(safe.minX, 59)
    }

    func testZoomKeepsViewportSizeAndClampsPanning() {
        let viewport = CGSize(width: 579.36, height: 393)
        let image = CGSize(width: 1920, height: 1200)
        let fit = DesktopGeometry.imageRect(image: image, viewport: viewport, aspectFit: true, zoom: 1, offset: .zero)
        XCTAssertEqual(fit.width, viewport.width, accuracy: 0.001)
        for offset in [CGPoint(x: -10000, y: -10000), CGPoint(x: 10000, y: 10000)] {
            let zoomed = DesktopGeometry.imageRect(image: image, viewport: viewport, aspectFit: true, zoom: 3, offset: offset)
            XCTAssertLessThanOrEqual(zoomed.minX, 0.001)
            XCTAssertLessThanOrEqual(zoomed.minY, 0.001)
            XCTAssertGreaterThanOrEqual(zoomed.maxX, viewport.width - 0.001)
            XCTAssertGreaterThanOrEqual(zoomed.maxY, viewport.height - 0.001)
            XCTAssertEqual(zoomed.width, fit.width * 3, accuracy: 0.001)
        }
    }
}
