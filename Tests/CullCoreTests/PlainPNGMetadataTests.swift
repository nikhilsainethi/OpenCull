import AppKit
import Foundation
import ImageIO
import XCTest
@testable import CullCore

final class PlainPNGMetadataTests: XCTestCase {
    private func fixture(alpha: Bool) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenCull-PlainPNG-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 20,
            bitsPerSample: 8, samplesPerPixel: alpha ? 4 : 3, hasAlpha: alpha, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for y in 0..<20 {
            for x in 0..<40 {
                bitmap.setColor(NSColor(calibratedRed: CGFloat(x) / 40, green: CGFloat(y) / 20,
                    blue: 0.2, alpha: alpha ? CGFloat(x + 1) / 41 : 1), atX: x, y: y)
            }
        }
        let file = root.appendingPathComponent("plain.png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file)
        return file
    }

    private func value(_ path: String, at file: URL) throws -> String? {
        let image = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
        guard let metadata = CGImageSourceCopyMetadataAtIndex(image, 0, nil) else { return nil }
        return CGImageMetadataCopyStringValueWithPath(metadata, nil, path as CFString) as String?
    }

    private func chunk(_ type: String, _ payload: Data) -> Data {
        var size = UInt32(payload.count).bigEndian
        var output = withUnsafeBytes(of: &size) { Data($0) }
        let checked = Data(type.utf8) + payload
        output.append(checked)
        var crc = UInt32.max
        for byte in checked {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1 }
        }
        var checksum = (crc ^ UInt32.max).bigEndian
        output.append(withUnsafeBytes(of: &checksum) { Data($0) })
        return output
    }

    private var foreignXMP: Data {
        Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" xmlns:qa="https://example.org/opencull-fixture/" qa:Retained="foreign-value"/></rdf:RDF></x:xmpmeta>
        """.utf8)
    }

    /// Compare original encoded chunks, including palette/profile/transparency and
    /// the compressed samples. Metadata synchronization must not re-encode pixels.
    private func nonXMPChunks(_ data: Data) throws -> [Data] {
        var offset = 8, chunks: [Data] = []
        while offset + 12 <= data.count {
            let length = data[offset..<(offset + 4)].reduce(0) { $0 * 256 + Int($1) }
            let end = offset + length + 12
            XCTAssertLessThanOrEqual(end, data.count)
            guard end <= data.count else { throw CocoaError(.fileReadCorruptFile) }
            let type = String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self)
            let payload = data[(offset + 8)..<(offset + 8 + length)]
            if type != "iTXt" || !payload.starts(with: Data("XML:com.adobe.xmp\0".utf8)) {
                chunks.append(data[offset..<end])
            }
            offset = end
        }
        XCTAssertEqual(offset, data.count)
        return chunks
    }

    func testCopyOfUnseededRGBAndAlphaPNGEmbedsChoicesWithoutReencoding() throws {
        for alpha in [false, true] {
            let original = try fixture(alpha: alpha)
            let bytes = try Data(contentsOf: original)
            XCTAssertNil(try value("xmp:Rating", at: original))
            var item = PhotoItem(url: original)
            item.decision = .pick; item.rating = 4
            let destination = original.deletingLastPathComponent().appendingPathComponent("Copies")
            let result = Exporter.copy([item], to: destination)
            XCTAssertEqual(result.copiedPhotos, 1, result.failures.joined(separator: "; "))
            XCTAssertTrue(result.failures.isEmpty)
            let copied = destination.appendingPathComponent(original.lastPathComponent)
            guard FileManager.default.fileExists(atPath: copied.path) else { continue }
            XCTAssertEqual(try value("xmp:Rating", at: copied), "4")
            XCTAssertEqual(try value("xmp:Label", at: copied), "Green")
            XCTAssertEqual(try nonXMPChunks(Data(contentsOf: copied)), try nonXMPChunks(bytes))
            XCTAssertEqual(try Data(contentsOf: original), bytes)
        }
    }

    func testChoicesCanBeChangedAndClearedAfterIntroducingPNGXMP() throws {
        let file = try fixture(alpha: true)
        let chunks = try nonXMPChunks(Data(contentsOf: file))
        try XMPSidecar.writeEmbedded(photo: file, decision: .pick, rating: 5)
        try XMPSidecar.writeEmbedded(photo: file, decision: .reject, rating: 0)
        XCTAssertEqual(try value("xmp:Rating", at: file), "-1")
        XCTAssertEqual(try value("xmp:Label", at: file), "Red")
        try XMPSidecar.writeEmbedded(photo: file, decision: .undecided, rating: 0)
        XCTAssertNil(try value("xmp:Rating", at: file))
        XCTAssertNil(try value("xmp:Label", at: file))
        XCTAssertEqual(try nonXMPChunks(Data(contentsOf: file)), chunks)
    }

    func testMalformedPNGChunksNeverReplaceThePassedCopy() throws {
        let file = try fixture(alpha: false)
        let original = try Data(contentsOf: file)
        let badChecksum = Data([0, 0, 0, 4]) + Data("tEXt".utf8) + Data("a\0bc".utf8) + Data([0, 0, 0, 0])
        let oversizedChunk = Data([127, 255, 255, 255]) + Data("tEXt".utf8)
        let cases = [
            original.prefix(33) + badChecksum + original.dropFirst(33),
            original.prefix(33) + oversizedChunk + original.dropFirst(33),
            original.dropLast(4),
            original + Data([0, 1, 2]),
        ]
        for malformed in cases {
            try malformed.write(to: file)
            XCTAssertThrowsError(try XMPSidecar.writeEmbedded(photo: file, decision: .pick, rating: 4))
            XCTAssertEqual(try Data(contentsOf: file), malformed)
        }
    }

    func testExistingForeignPNGXMPIsRetained() throws {
        let file = try fixture(alpha: true)
        let original = try Data(contentsOf: file)
        let packet = chunk("iTXt", Data("XML:com.adobe.xmp\0\0\0\0\0".utf8) + foreignXMP)
        try (original.prefix(33) + packet + original.dropFirst(33)).write(to: file)
        XCTAssertEqual(try value("qa:Retained", at: file), "foreign-value")
        let before = try nonXMPChunks(Data(contentsOf: file))
        try XMPSidecar.writeEmbedded(photo: file, decision: .pick, rating: 4)
        XCTAssertEqual(try value("qa:Retained", at: file), "foreign-value")
        XCTAssertEqual(try value("xmp:Rating", at: file), "4")
        try XMPSidecar.writeEmbedded(photo: file, decision: .undecided, rating: 0)
        XCTAssertEqual(try value("qa:Retained", at: file), "foreign-value")
        XCTAssertEqual(try nonXMPChunks(Data(contentsOf: file)), before)
    }

    func testUnsupportedOrAmbiguousPNGXMPFailsWithoutDeletingForeignPackets() throws {
        let file = try fixture(alpha: false)
        let plain = try Data(contentsOf: file)
        let canonical = chunk("iTXt", Data("XML:com.adobe.xmp\0\0\0\0\0".utf8) + foreignXMP)
        let variants = [
            chunk("tEXt", Data("XML:com.adobe.xmp\0".utf8) + foreignXMP),
            chunk("zTXt", Data("XML:com.adobe.xmp\0\0".utf8) + Data(base64Encoded: "eJw9j00OgyAUhK9i6Bpfa1cSdWV6AG+A+rQk/AlY6e2LLeluZjL5MtNEFpVVGHgRldSexZbw2YzIkj5jIF3j5oUN/SM3kmvJMwTLAI7jKI97adwKt7qu4VpBVdHUoP6tA49U+0sG9OgnJ2wQRhen56PZQ0tIpm78B/WJipErK/GLNRb1tEtJFxHD7hBIsXE2pGVC49ySxTgUq6YvLnck0DWQ1yb1/9Z9AAIfT8U=")!),
            canonical + canonical,
            chunk("iTXt", Data("XML:com.adobe.xmp\0\0\0\0\0not-xml".utf8)),
        ]
        for (index, packet) in variants.enumerated() {
            let original = plain.prefix(33) + packet + plain.dropFirst(33)
            try original.write(to: file)
            XCTAssertThrowsError(try XMPSidecar.writeEmbedded(photo: file, decision: .pick, rating: 4), "variant \(index)")
            XCTAssertEqual(try Data(contentsOf: file), original)
            var item = PhotoItem(url: file); item.decision = .pick; item.rating = 4
            let destination = file.deletingLastPathComponent().appendingPathComponent("Unsupported-\(index)")
            let result = Exporter.copy([item], to: destination)
            XCTAssertEqual(result.copiedPhotos, 0)
            XCTAssertFalse(result.failures.isEmpty)
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []
            XCTAssertTrue(leftovers.isEmpty, "Failed bundles must not leave a photo, sidecar or staging directory")
            XCTAssertEqual(try Data(contentsOf: file), original)
        }
    }
}
