import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import CullCore

final class EmbeddedMetadataTests: XCTestCase {
    private func fixture(type: String, ext: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenCull-Embedded-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("rendered." + ext)
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 128, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0.3, green: 0.6, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        let metadata = CGImageMetadataCreateMutable()
        XCTAssertTrue(CGImageMetadataRegisterNamespaceForPrefix(metadata, "http://ns.adobe.com/xap/1.0/" as CFString, "xmp" as CFString, nil))
        XCTAssertTrue(CGImageMetadataRegisterNamespaceForPrefix(metadata, "http://ns.adobe.com/tiff/1.0/" as CFString, "tiff" as CFString, nil))
        XCTAssertTrue(CGImageMetadataRegisterNamespaceForPrefix(metadata, "http://ns.adobe.com/exif/1.0/" as CFString, "exif" as CFString, nil))
        XCTAssertTrue(CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Rating" as CFString, "-1" as CFString))
        XCTAssertTrue(CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Label" as CFString, "Red" as CFString))
        XCTAssertTrue(CGImageMetadataSetValueWithPath(metadata, nil, "xmp:CreatorTool" as CFString, "Metadata Test" as CFString))
        XCTAssertTrue(CGImageMetadataSetValueWithPath(metadata, nil, "tiff:Artist" as CFString, "Fixture Artist" as CFString))
        XCTAssertTrue(CGImageMetadataSetValueWithPath(metadata, nil, "exif:ExposureTime" as CFString, "1/100" as CFString))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Fixture Artist"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifExposureTime: 0.01],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCKeywords: ["retained-keyword"]],
        ]
        CGImageDestinationAddImageAndMetadata(destination, try XCTUnwrap(context.makeImage()), metadata, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func metadata(_ photo: URL) throws -> CGImageMetadata {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(photo as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCopyMetadataAtIndex(source, 0, nil))
    }

    private func value(_ path: String, in metadata: CGImageMetadata) -> String? {
        CGImageMetadataCopyStringValueWithPath(metadata, nil, path as CFString) as String?
    }

    private func properties(_ photo: URL) throws -> NSDictionary {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(photo as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil)) as NSDictionary
    }

    private func pixels(_ photo: URL) throws -> Data {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(photo as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: image.width * image.height * 4)
    }

    func testCurrentChoicesAreEmbeddedInJPEGPNGAndTIFFWithoutChangingPixels() throws {
        for (type, ext) in [("public.jpeg", "jpg"), ("public.png", "png"), ("public.tiff", "tif")] {
            let photo = try fixture(type: type, ext: ext)
            let beforePixels = try pixels(photo), before = try metadata(photo), beforeProperties = try properties(photo)
            try XMPSidecar.writeEmbedded(photo: photo, decision: .pick, rating: 5)
            let after = try metadata(photo)
            XCTAssertEqual(value("xmp:Rating", in: after), "5", ext)
            XCTAssertEqual(value("xmp:Label", in: after), "Green", ext)
            XCTAssertEqual(value("xmp:CreatorTool", in: after), value("xmp:CreatorTool", in: before), ext)
            let afterProperties = try properties(photo)
            if ext != "png" {
                // JPEG writers normalize TIFF Artist into IPTC Byline.
                let originalArtist = (beforeProperties[kCGImagePropertyTIFFDictionary] as? NSDictionary)?[kCGImagePropertyTIFFArtist] as? String
                XCTAssertEqual((afterProperties[kCGImagePropertyTIFFDictionary] as? NSDictionary)?[kCGImagePropertyTIFFArtist] as? String, originalArtist, ext)
                XCTAssertEqual(afterProperties[kCGImagePropertyExifDictionary] as? NSDictionary, beforeProperties[kCGImagePropertyExifDictionary] as? NSDictionary, ext)
                let beforeIPTC = try XCTUnwrap(beforeProperties[kCGImagePropertyIPTCDictionary] as? NSDictionary).mutableCopy() as! NSMutableDictionary
                let afterIPTC = try XCTUnwrap(afterProperties[kCGImagePropertyIPTCDictionary] as? NSDictionary).mutableCopy() as! NSMutableDictionary
                XCTAssertEqual(beforeIPTC[kCGImagePropertyIPTCByline] as? [String], ["Fixture Artist"], ext)
                // ImageIO also synchronizes IPTC StarRating; every unrelated field must remain.
                beforeIPTC.removeObject(forKey: kCGImagePropertyIPTCStarRating)
                afterIPTC.removeObject(forKey: kCGImagePropertyIPTCStarRating)
                XCTAssertEqual(afterIPTC, beforeIPTC, ext)
            } else {
                XCTAssertTrue(String(decoding: CGImageMetadataCreateXMPData(before, nil)! as Data, as: UTF8.self).contains("Fixture Artist"))
                XCTAssertTrue(String(decoding: CGImageMetadataCreateXMPData(after, nil)! as Data, as: UTF8.self).contains("Fixture Artist"))
            }
            XCTAssertEqual(afterProperties[kCGImagePropertyProfileName] as? String, beforeProperties[kCGImagePropertyProfileName] as? String, ext)
            XCTAssertEqual(value("exif:ExposureTime", in: after), value("exif:ExposureTime", in: before), ext)
            XCTAssertEqual(try pixels(photo), beforePixels, ext)
        }
    }

    func testClearedChoiceRemovesStaleEmbeddedRatingAndLabel() throws {
        for (type, ext) in [("public.jpeg", "jpg"), ("public.png", "png"), ("public.tiff", "tif")] {
            let photo = try fixture(type: type, ext: ext)
            try XMPSidecar.writeEmbedded(photo: photo, decision: .undecided, rating: 0)
            let after = try metadata(photo)
            XCTAssertNil(value("xmp:Rating", in: after), ext)
            XCTAssertNil(value("xmp:Label", in: after), ext)
            XCTAssertEqual(value("xmp:CreatorTool", in: after), "Metadata Test", ext)
        }
    }

    func testEmbeddedWriteRejectsSymbolicLinksWithoutChangingTarget() throws {
        let target = try fixture(type: "public.png", ext: "png")
        let link = target.deletingLastPathComponent().appendingPathComponent("linked.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let original = try Data(contentsOf: target)
        XCTAssertThrowsError(try XMPSidecar.writeEmbedded(photo: link, decision: .pick, rating: 5))
        XCTAssertEqual(try Data(contentsOf: target), original)
    }

    func testCopyPicksEmbedsCurrentChoicesInStandardCopiesOnly() throws {
        for (type, ext) in [("public.jpeg", "jpg"), ("public.png", "png"), ("public.tiff", "tif")] {
            let photo = try fixture(type: type, ext: ext)
            let originalBytes = try Data(contentsOf: photo), originalPixels = try pixels(photo)
            var item = PhotoItem(url: photo); item.decision = .pick; item.rating = 5
            let destination = photo.deletingLastPathComponent().appendingPathComponent("Export")
            let copied = Exporter.copy([item], to: destination)
            XCTAssertEqual(copied.copiedPhotos, 1, ext)
            XCTAssertTrue(copied.failures.isEmpty, copied.failures.joined(separator: "; "))
            let output = destination.appendingPathComponent(photo.lastPathComponent)
            let exported = try metadata(output)
            XCTAssertEqual(value("xmp:Rating", in: exported), "5", ext)
            XCTAssertEqual(value("xmp:Label", in: exported), "Green", ext)
            XCTAssertEqual(value("xmp:CreatorTool", in: exported), "Metadata Test", ext)
            XCTAssertEqual(try Data(contentsOf: photo), originalBytes, ext)
            XCTAssertEqual(try pixels(output), originalPixels, ext)
        }
    }
}
