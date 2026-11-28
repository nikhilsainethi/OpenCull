import CoreGraphics
import XCTest
@testable import OpenCull

final class EditorViewGeometryTests: XCTestCase {
    func testActualZoomMapsEachImagePixelToOnePhysicalDisplayPixel() {
        for backing in [CGFloat(1), 2, 3] {
            let layout = PhotoViewportGeometry.layout(image: CGSize(width: 1200, height: 800), viewport: CGSize(width: 600, height: 400),
                                                       backingScale: backing, zoom: .actual, face: nil)
            XCTAssertEqual(layout.imageRect.width * backing, 1200, accuracy: 0.000001)
            XCTAssertEqual(layout.imageRect.height * backing, 800, accuracy: 0.000001)
        }
    }
    func testActualZoomCanCenterTheMatchedFaceOnStandardAndRetinaScreens() {
        // Analysis coordinates refer to the upright photo with origin at the top left.
        let upperRight = CGRect(x: 0.7, y: 0.1, width: 0.1, height: 0.2)
        for backing: CGFloat in [1, 2] {
            let layout = PhotoViewportGeometry.layout(image: CGSize(width: 2000, height: 1000),
                viewport: CGSize(width: 320, height: 200), backingScale: backing, zoom: .actual, face: upperRight)
            XCTAssertEqual(layout.imageRect.width * backing, 2000, accuracy: 0.000001)
            XCTAssertEqual(layout.center.x * backing, 1500, accuracy: 0.000001)
            XCTAssertEqual(layout.center.y * backing, 200, accuracy: 0.000001)
        }
    }

    func testFaceCenteredScrollOriginStaysInsideTheImageAndOnPhysicalPixels() {
        let origin = PhotoViewportGeometry.scrollOrigin(center: CGPoint(x: 300.33, y: 502.8),
            canvas: CGSize(width: 1000, height: 600), viewport: CGSize(width: 300, height: 201),
            backingScale: 2)
        XCTAssertEqual(origin, CGPoint(x: 150.5, y: 399))
    }

    func testFitKeepsWholeImageInsideViewport() {
        let layout = PhotoViewportGeometry.layout(image: CGSize(width: 1200, height: 800), viewport: CGSize(width: 300, height: 300),
                                                   backingScale: 2, zoom: .fit, face: nil)
        XCTAssertEqual(layout.imageRect.width, 300)
        XCTAssertEqual(layout.imageRect.height, 200)
        XCTAssertEqual(layout.imageRect.minY, 50)
    }
    func testFaceZoomCentersOnSelectedFaceAndDoesNotDropBelowActualPixels() {
        let face = CGRect(x: 0.7, y: 0.2, width: 0.1, height: 0.2)
        let layout = PhotoViewportGeometry.layout(image: CGSize(width: 2000, height: 1000), viewport: CGSize(width: 500, height: 400),
                                                   backingScale: 2, zoom: .face, face: face)
        XCTAssertGreaterThanOrEqual(layout.imageRect.width, 1000)
        XCTAssertEqual(layout.center.x, layout.imageRect.minX + face.midX * layout.imageRect.width)
        XCTAssertEqual(layout.center.y, layout.imageRect.minY + face.midY * layout.imageRect.height)
    }
    func testActualZoomCentersSmallPhotosOnPhysicalPixelBoundaries() {
        let layout = PhotoViewportGeometry.layout(image: CGSize(width: 400, height: 300), viewport: CGSize(width: 500.5, height: 400.25),
                                                   backingScale: 2, zoom: .actual, face: nil)
        XCTAssertEqual((layout.imageRect.minX * 2).rounded(), layout.imageRect.minX * 2)
        XCTAssertEqual((layout.imageRect.minY * 2).rounded(), layout.imageRect.minY * 2)
    }
}
