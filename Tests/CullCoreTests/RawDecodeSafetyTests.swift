import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import CullCore

final class RawDecodeSafetyTests: XCTestCase {
    private func disguisedImage(extension ext: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OpenCull-RawSafety-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("preview").appendingPathExtension(ext)
        let pixels = Data(repeating: 120, count: 64 * 48)
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let image = try XCTUnwrap(CGImage(width: 64, height: 48, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 64,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    func testPreviewLikeContainerCannotMasqueradeAsFullResolutionRaw() throws {
        for ext in ["dng", "kdc"] {
            let url = try disguisedImage(extension: ext)
            XCTAssertThrowsError(try PhotoEditor.render(url: url))
            XCTAssertThrowsError(try PhotoEditor.render(url: url, maxPixelSize: 32))
        }
    }

    func testUnsupportedRawPreviewProducesExplicitAnalysisWarning() throws {
        let url = try disguisedImage(extension: "kdc")
        let analysis = try PhotoAnalyzer().analyze(url: url)
        XCTAssertTrue(analysis.analysisWarnings.contains { $0.localizedCaseInsensitiveContains("RAW") && $0.localizedCaseInsensitiveContains("preview") })
        var photo = PhotoItem(url: url); photo.analysis = analysis
        var photos = [photo]; Scorer.evaluate(&photos)
        XCTAssertTrue(photos[0].needsReview)
        XCTAssertEqual(photos[0].suggestion, .undecided)
    }

    func testUnsupportedRawExportPublishesNoThumbnailAsEditedPhoto() throws {
        let url = try disguisedImage(extension: "dng")
        let output = url.deletingLastPathComponent().appendingPathComponent("output")
        XCTAssertThrowsError(try PhotoEditor.export(url: url, to: output, format: .jpeg))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
    }

    func testOrdinaryPngDoesNotRequireRawDecoder() throws {
        let url = try disguisedImage(extension: "png")
        let image = try PhotoEditor.render(url: url)
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 48)
    }
}
