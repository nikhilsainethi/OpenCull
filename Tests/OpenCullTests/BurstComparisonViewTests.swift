import CullCore
import ImageIO
import XCTest
@testable import OpenCull

final class BurstComparisonViewTests: XCTestCase {
    func testDefaultBurstViewFramesEitherASmallOrLargeFaceAndKeepsActualAvailable() {
        let pane = CGSize(width: 360, height: 230)
        for (pixels, face) in [
            (CGSize(width: 744, height: 418), CGRect(x: 0.63, y: 0.22, width: 0.12, height: 0.28)),
            (CGSize(width: 6000, height: 4000), CGRect(x: 0.35, y: 0.15, width: 0.3, height: 0.5))
        ] {
            let detail = PhotoViewportGeometry.layout(image: pixels, viewport: pane, backingScale: 2,
                zoom: BurstComparisonSheet.initialZoom, face: face, frameBurstFace: true)
            let actual = PhotoViewportGeometry.layout(image: pixels, viewport: pane, backingScale: 2,
                zoom: .actual, face: face, frameBurstFace: true)
            XCTAssertEqual(actual.imageRect.width * 2, pixels.width)
            let height = detail.imageRect.height * face.height
            XCTAssertGreaterThan(height, pane.height * 0.50)
            XCTAssertLessThanOrEqual(height, pane.height * 0.75)
            XCTAssertEqual(detail.center.x, detail.imageRect.minX + face.midX * detail.imageRect.width, accuracy: 0.01)
            XCTAssertEqual(detail.center.y, detail.imageRect.minY + face.midY * detail.imageRect.height, accuracy: 0.01)
        }
    }

    func testInspectionUsesOriginalFaceIndexAndDoesNotSubstituteTheLargestFace() {
        let small = FaceInfo(boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.06, height: 0.08))
        let large = FaceInfo(boundingBox: CGRect(x: 0.4, y: 0.1, width: 0.2, height: 0.3))
        XCTAssertEqual(BurstComparisonSheet.face(at: 0, in: [small, large]), small)
        XCTAssertNil(BurstComparisonSheet.face(at: nil, in: [small, large]))
        XCTAssertNil(BurstComparisonSheet.face(at: 2, in: [small, large]))
    }

    func testFullSizePreviewPlacesUprightFaceOnTheExpectedSourcePixels() async throws {
        // With EXIF orientation 6, the red left half becomes the upper half.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).tiff")
        defer { try? FileManager.default.removeItem(at: url) }
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8,
            bytesPerRow: 320, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        bitmap.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(bitmap.makeImage()), [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        let decoded = await PreviewCache.shared.image(for: PhotoItem(url: url), size: 0, recipe: .identity)
        let preview = try XCTUnwrap(decoded)
        XCTAssertEqual(preview.width, 40)
        XCTAssertEqual(preview.height, 80)
        let face = CGRect(x: 0.4, y: 0.15, width: 0.2, height: 0.2)
        let viewport = PhotoViewportGeometry.layout(image: CGSize(width: preview.width, height: preview.height),
            viewport: CGSize(width: 4, height: 4), backingScale: 2, zoom: .actual, face: face)
        let crop = try XCTUnwrap(preview.cropping(to: CGRect(x: viewport.center.x * 2, y: viewport.center.y * 2,
                                                            width: 1, height: 1)))
        let sample = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        sample.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let rgba = try XCTUnwrap(sample.data?.assumingMemoryBound(to: UInt8.self))
        XCTAssertGreaterThan(rgba[0], 200)
        XCTAssertLessThan(rgba[2], 20)
    }

    func testUnsupportedRawUsesItsOwnAvailablePixelsBeforeADifferentlyFramedCompanion() async throws {
        let (raw, companion) = try makeRawAndCompanion()
        try writePNG(width: 80, height: 40, to: raw)
        let item = PhotoItem(url: raw, companions: [companion])
        let preview = await PreviewCache.shared.burstPreview(for: item, size: 0)
        XCTAssertEqual(preview.source, .embeddedRaw)
        guard case .image(let image) = preview.result else { return XCTFail("Embedded pixels should be available") }
        XCTAssertEqual(image.width, 80)
        XCTAssertEqual(image.height, 40)

        // The editor has a separate cache and still requires a full decode or companion.
        let edited = await PreviewCache.shared.image(for: item, size: 0)
        XCTAssertEqual(edited?.height, 96)
    }

    func testOversizedReviewRepresentationDisclosesItsDecodeLimit() async throws {
        let (raw, _) = try makeRawAndCompanion()
        try writePNG(width: 8500, height: 32, to: raw)
        let preview = await PreviewCache.shared.burstPreview(for: PhotoItem(url: raw), size: 0)
        XCTAssertEqual(preview.source, .limitedRaw(8192))
        guard case .image(let image) = preview.result else { return XCTFail("Expected a bounded preview") }
        XCTAssertEqual(image.width, 8192)
    }

    func testUnreadableRawLabelsTheSameCompanionUsedForAnalysis() async throws {
        let (raw, companion) = try makeRawAndCompanion()
        try Data([0, 1, 2, 3]).write(to: raw)
        let preview = await PreviewCache.shared.burstPreview(for: PhotoItem(url: raw, companions: [companion]), size: 0)
        XCTAssertEqual(preview.source, .companion(companion.lastPathComponent))
        guard case .image(let image) = preview.result else { return XCTFail("Companion pixels should be available") }
        XCTAssertEqual(image.width, 48)
        XCTAssertEqual(image.height, 96)
    }

    private func makeRawAndCompanion() throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let companion = directory.appendingPathComponent("shot.png")
        try writePNG(width: 48, height: 96, to: companion)
        return (directory.appendingPathComponent("shot.kdc"), companion)
    }

    private func writePNG(width: Int, height: Int, to url: URL) throws {
        let pixels = Data(repeating: 100, count: width * height)
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    func testMalformedBoxCannotDisplayAnUnrelatedCrop() {
        for box in [CGRect.null, .zero, CGRect(x: 0.9, y: 0, width: 0.2, height: 0.1),
                    CGRect(x: 0.1, y: 0.1, width: -0.1, height: 0.3)] {
            XCTAssertNil(BurstComparisonSheet.face(at: 0, in: [FaceInfo(boundingBox: box)]))
        }
    }
}
