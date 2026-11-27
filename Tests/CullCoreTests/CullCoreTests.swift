import CoreGraphics
import Foundation
import XCTest
@testable import CullCore

// MARK: - Helpers

private func noiseImage(width: Int, height: Int, seed: UInt64 = 42) -> GrayImage {
    var state = seed
    var pixels = [UInt8](repeating: 0, count: width * height)
    for i in pixels.indices {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        pixels[i] = UInt8(truncatingIfNeeded: state >> 56)
    }
    return GrayImage(width: width, height: height, pixels: pixels)
}

/// Repeated 3x3 box blur.
private func blurred(_ image: GrayImage, passes: Int) -> GrayImage {
    var p = image.pixels
    let w = image.width, h = image.height
    for _ in 0..<passes {
        var out = p
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                var sum = 0
                for dy in -1...1 { for dx in -1...1 { sum += Int(p[(y + dy) * w + x + dx]) } }
                out[y * w + x] = UInt8(sum / 9)
            }
        }
        p = out
    }
    return GrayImage(width: w, height: h, pixels: p)
}

private func cgImage(from gray: GrayImage) -> CGImage {
    let data = Data(gray.pixels) as CFData
    let provider = CGDataProvider(data: data)!
    return CGImage(width: gray.width, height: gray.height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: gray.width,
                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                   decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

private func analysis(sharpness: Float = 500, eyes: Float? = nil, date: Date? = nil, embedding: [Float]? = [1, 0],
                      luminance: Float = 0.5, highlights: Float = 0, shadows: Float = 0) -> PhotoAnalysis {
    let faces = eyes.map { [FaceInfo(boundingBox: CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.25), captureQuality: 0.6,
                                     eyeOpenness: $0, sharpness: sharpness)] } ?? []
    return PhotoAnalysis(pixelWidth: 100, pixelHeight: 100, captureDate: date, sharpness: sharpness, subjectSharpness: sharpness,
                         meanLuminance: luminance, highlightClipping: highlights, shadowClipping: shadows, faces: faces,
                         aestheticScore: nil, isUtility: nil, featurePrint: embedding.flatMap(Embedding.normalized))
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("OpenCullTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - Sharpness and exposure

final class GrayImageTests: XCTestCase {
    func testBlurReducesSharpness() {
        let sharp = noiseImage(width: 256, height: 192)
        let soft = blurred(sharp, passes: 1)
        let verySoft = blurred(sharp, passes: 4)
        XCTAssertGreaterThan(sharp.tiledSharpness(), soft.tiledSharpness() * 3)
        XCTAssertGreaterThan(soft.tiledSharpness(), verySoft.tiledSharpness())
    }

    func testFlatImageHasZeroSharpness() {
        let flat = GrayImage(width: 64, height: 64, pixels: [UInt8](repeating: 128, count: 64 * 64))
        XCTAssertEqual(flat.tiledSharpness(), 0)
    }

    func testSharpSubjectOnBlurredBackgroundStillCountsAsSharp() {
        // Mostly blurred frame with one sharp patch: the tiled measure should stay high.
        let sharp = noiseImage(width: 384, height: 384)
        var pixels = blurred(sharp, passes: 4).pixels
        for y in 150..<230 { for x in 150..<230 { pixels[y * 384 + x] = sharp.pixels[y * 384 + x] } }
        let mixed = GrayImage(width: 384, height: 384, pixels: pixels)
        let wholeFrame = mixed.laplacianVariance(x0: 0, y0: 0, x1: 384, y1: 384)
        XCTAssertGreaterThan(mixed.tiledSharpness(), wholeFrame * 3)
    }

    func testLayoutSignatureToleratesBlurButSeparatesScenes() throws {
        // Diagonal gradient with fine noise, then the same scene blurred, then a different scene.
        let noise = noiseImage(width: 192, height: 128)
        var scene = [UInt8](repeating: 0, count: 192 * 128)
        var other = scene
        for y in 0..<128 {
            for x in 0..<192 {
                let n = Int(noise.pixels[y * 192 + x]) / 8
                scene[y * 192 + x] = UInt8(min(255, x + y / 2 + n))
                other[y * 192 + x] = UInt8(min(255, 255 - x + n))
            }
        }
        let a = GrayImage(width: 192, height: 128, pixels: scene)
        let blurredA = blurred(a, passes: 6)
        let b = GrayImage(width: 192, height: 128, pixels: other)
        let la = try XCTUnwrap(a.layoutSignature()), lab = try XCTUnwrap(blurredA.layoutSignature()), lb = try XCTUnwrap(b.layoutSignature())
        XCTAssertGreaterThan(la.similarity(to: lab), 0.97)
        XCTAssertLessThan(la.similarity(to: lb), 0.5)
    }

    func testExposure() {
        let white = GrayImage(width: 10, height: 10, pixels: [UInt8](repeating: 255, count: 100))
        let black = GrayImage(width: 10, height: 10, pixels: [UInt8](repeating: 0, count: 100))
        XCTAssertEqual(white.exposure().highlightClipping, 1)
        XCTAssertEqual(white.exposure().mean, 1, accuracy: 0.001)
        XCTAssertEqual(black.exposure().shadowClipping, 1)
        XCTAssertEqual(black.exposure().mean, 0, accuracy: 0.001)
        let half = GrayImage(width: 10, height: 10, pixels: [UInt8](repeating: 0, count: 50) + [UInt8](repeating: 255, count: 50))
        XCTAssertEqual(half.exposure().highlightClipping, 0.5, accuracy: 0.001)
        XCTAssertEqual(half.exposure().shadowClipping, 0.5, accuracy: 0.001)
    }

    func testGrayImageFromCGImageKeepsTopRowFirst() {
        var pixels = [UInt8](repeating: 0, count: 8 * 8)
        for x in 0..<8 { pixels[x] = 255 } // top row white
        let image = cgImage(from: GrayImage(width: 8, height: 8, pixels: pixels))
        let gray = GrayImage(cgImage: image)!
        XCTAssertEqual(gray.pixels[0], 255)
        XCTAssertEqual(gray.pixels[63], 0)
    }
}

// MARK: - Eye openness geometry

final class EyeOpennessTests: XCTestCase {
    private func eye(width: CGFloat, height: CGFloat, angle: CGFloat = 0) -> [CGPoint] {
        (0..<8).map { k in
            let t = CGFloat(k) / 8 * 2 * .pi
            let x = cos(t) * width / 2, y = sin(t) * height / 2
            return CGPoint(x: 100 + x * cos(angle) - y * sin(angle), y: 100 + x * sin(angle) + y * cos(angle))
        }
    }

    func testOpenEyeIsMoreOpenThanClosedEye() throws {
        let open = try XCTUnwrap(PhotoAnalyzer.eyeOpenness(points: eye(width: 30, height: 12)))
        let closed = try XCTUnwrap(PhotoAnalyzer.eyeOpenness(points: eye(width: 30, height: 2)))
        XCTAssertEqual(open, 0.4, accuracy: 0.02)
        XCTAssertLessThan(closed, 0.1)
    }

    func testHeadTiltDoesNotChangeOpenness() throws {
        let level = try XCTUnwrap(PhotoAnalyzer.eyeOpenness(points: eye(width: 30, height: 9)))
        let tilted = try XCTUnwrap(PhotoAnalyzer.eyeOpenness(points: eye(width: 30, height: 9, angle: 0.5)))
        XCTAssertEqual(level, tilted, accuracy: 0.01)
    }

    func testTooFewPoints() {
        XCTAssertNil(PhotoAnalyzer.eyeOpenness(points: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]))
    }
}

// MARK: - Dates, embeddings, grouping

final class GroupingTests: XCTestCase {
    func testExifDateWithSubsecondsAndOffset() throws {
        let a = try XCTUnwrap(ImageLoader.parseExifDate("2024:06:01 14:03:22", subseconds: "45", offset: "+02:00"))
        let b = try XCTUnwrap(ImageLoader.parseExifDate("2024:06:01 12:03:22", subseconds: "95", offset: nil))
        XCTAssertEqual(b.timeIntervalSince(a), 0.5, accuracy: 0.0001)
        XCTAssertNil(ImageLoader.parseExifDate("not a date", subseconds: nil, offset: nil))
    }

    func testEmbeddingRoundTripAndSimilarity() throws {
        let e = try XCTUnwrap(Embedding.normalized([3, 4]))
        XCTAssertEqual(e.values, [0.6, 0.8])
        let decoded = try PropertyListDecoder().decode([Embedding].self, from: PropertyListEncoder().encode([e]))
        XCTAssertEqual(decoded.first, e)
        XCTAssertEqual(e.similarity(to: e), 1, accuracy: 0.0001)
        XCTAssertNil(Embedding.normalized([0, 0]))
    }

    func testBurstIsGroupedAndSceneChangeSplits() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let inputs: [Grouper.Input] = [
            .init(name: "a", date: t0, embedding: Embedding.normalized([1, 0.05])),
            .init(name: "b", date: t0.addingTimeInterval(0.3), embedding: Embedding.normalized([1, 0.0])),
            .init(name: "c", date: t0.addingTimeInterval(0.6), embedding: Embedding.normalized([1, 0.1])),
            // Different scene, shot right after: new group.
            .init(name: "d", date: t0.addingTimeInterval(1.0), embedding: Embedding.normalized([0, 1])),
            // Same look as d but a minute later: new group.
            .init(name: "e", date: t0.addingTimeInterval(61), embedding: Embedding.normalized([0, 1])),
        ]
        XCTAssertEqual(Grouper.group(inputs), [0, 0, 0, 1, 2])
    }

    func testGroupingFollowsCaptureTimeNotInputOrder() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let inputs: [Grouper.Input] = [
            .init(name: "z", date: t0.addingTimeInterval(100), embedding: Embedding.normalized([0, 1])),
            .init(name: "a", date: t0, embedding: Embedding.normalized([1, 0])),
        ]
        XCTAssertEqual(Grouper.group(inputs), [1, 0])
    }

    func testBlurredFrameStaysInBurstThroughLayoutSimilarity() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let inputs: [Grouper.Input] = [
            .init(name: "sharp", date: t0, embedding: Embedding.normalized([1, 0]), layout: Embedding.normalized([1, 1, 0])),
            // Vision embedding drifted (blur) but the layout is the same.
            .init(name: "blurred", date: t0.addingTimeInterval(0.2), embedding: Embedding.normalized([0.6, 0.8]),
                  layout: Embedding.normalized([1, 0.95, 0.05])),
        ]
        XCTAssertEqual(Grouper.group(inputs), [0, 0])
    }

    func testMissingEmbeddingNeverGroups() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let inputs: [Grouper.Input] = [
            .init(name: "a", date: t0, embedding: nil),
            .init(name: "b", date: t0, embedding: nil),
        ]
        XCTAssertEqual(Set(Grouper.group(inputs)).count, 2)
    }
}

// MARK: - Scoring

final class ScorerTests: XCTestCase {
    func testIssues() {
        let options = ScoringOptions()
        XCTAssertEqual(Scorer.issues(for: analysis(sharpness: 10), groupMaxSharpness: nil, options: options), [.blurry])
        XCTAssertEqual(Scorer.issues(for: analysis(eyes: 0.05), groupMaxSharpness: nil, options: options), [.eyesClosed])
        XCTAssertEqual(Scorer.issues(for: analysis(eyes: 0.35), groupMaxSharpness: nil, options: options), [])
        XCTAssertEqual(Scorer.issues(for: analysis(highlights: 0.3), groupMaxSharpness: nil, options: options), [.overexposed])
        XCTAssertEqual(Scorer.issues(for: analysis(luminance: 0.05, shadows: 0.6), groupMaxSharpness: nil, options: options), [.underexposed])
        // Sharp on its own, but much softer than the best shot of its group.
        XCTAssertEqual(Scorer.issues(for: analysis(sharpness: 200), groupMaxSharpness: 1000, options: options), [.blurry])
    }

    func testSmallFacesAreIgnoredForEyeChecks() {
        var a = analysis(eyes: 0.02)
        a.faces[0].boundingBox.size.width = 0.01
        XCTAssertFalse(Scorer.hasClosedEyes(a, options: ScoringOptions()))
    }

    func testBestShotOfBurstIsPickedAndOthersSuggestedForRejection() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var items = (0..<4).map { PhotoItem(url: URL(fileURLWithPath: "/tmp/IMG_\($0).jpg")) }
        items[0].analysis = analysis(sharpness: 600, eyes: 0.30, date: t0)
        items[1].analysis = analysis(sharpness: 900, eyes: 0.32, date: t0.addingTimeInterval(0.2)) // best
        items[2].analysis = analysis(sharpness: 880, eyes: 0.05, date: t0.addingTimeInterval(0.4)) // blink
        items[3].analysis = analysis(sharpness: 700, eyes: 0.30, date: t0.addingTimeInterval(30), embedding: [0, 1]) // new scene
        Scorer.evaluate(&items)

        XCTAssertEqual(items[0].groupID, items[1].groupID)
        XCTAssertEqual(items[1].groupID, items[2].groupID)
        XCTAssertNotEqual(items[3].groupID, items[0].groupID)
        XCTAssertTrue(items[1].isBestInGroup)
        XCTAssertEqual(items[1].suggestion, .pick)
        XCTAssertEqual(items[0].suggestion, .reject)
        XCTAssertTrue(items[0].issues.contains(.duplicate))
        XCTAssertEqual(items[2].suggestion, .reject)
        XCTAssertTrue(items[2].issues.contains(.eyesClosed))
        XCTAssertEqual(items[3].suggestion, .pick)
        XCTAssertEqual(items[3].groupSize, 1)
        XCTAssertFalse(items[3].isBestInGroup)
    }

    func testUserDecisionsAreNotChangedByEvaluation() {
        var items = [PhotoItem(url: URL(fileURLWithPath: "/tmp/a.jpg"))]
        items[0].analysis = analysis(sharpness: 5)
        items[0].decision = .pick
        items[0].rating = 4
        Scorer.evaluate(&items)
        XCTAssertEqual(items[0].suggestion, .reject)
        XCTAssertEqual(items[0].decision, .pick)
        XCTAssertEqual(items[0].rating, 4)
    }
}

// MARK: - XMP sidecars

final class XMPTests: XCTestCase {
    func testValues() {
        XCTAssertEqual(XMPSidecar.values(decision: .pick, rating: 0), .init(rating: 1, label: "Green"))
        XCTAssertEqual(XMPSidecar.values(decision: .pick, rating: 4), .init(rating: 4, label: "Green"))
        XCTAssertEqual(XMPSidecar.values(decision: .reject, rating: 3), .init(rating: -1, label: "Red"))
        XCTAssertEqual(XMPSidecar.values(decision: .undecided, rating: 2), .init(rating: 2, label: nil))
        XCTAssertNil(XMPSidecar.values(decision: .undecided, rating: 0))
    }

    func testNewDocumentIsValidXML() throws {
        let doc = XMPSidecar.makeDocument(.init(rating: 3, label: "Green"))
        let xml = try XMLDocument(xmlString: doc)
        let description = try XCTUnwrap(try xml.nodes(forXPath: "//*[local-name()='Description']").first as? XMLElement)
        XCTAssertEqual(description.attribute(forName: "xmp:Rating")?.stringValue, "3")
        XCTAssertEqual(description.attribute(forName: "xmp:Label")?.stringValue, "Green")
    }

    func testUpdateKeepsOtherMetadata() throws {
        let lightroom = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
            xmp:Rating="2"
            crs:Exposure2012="+0.50">
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """
        let updated = try XCTUnwrap(XMPSidecar.update(existing: lightroom, with: .init(rating: 5, label: "Green")))
        XCTAssertTrue(updated.contains("xmp:Rating=\"5\""))
        XCTAssertFalse(updated.contains("xmp:Rating=\"2\""))
        let resultXML = try XMLDocument(xmlString: updated)
        let resultDescription = try XCTUnwrap(try resultXML.nodes(forXPath: "//*[local-name()='Description']").first as? XMLElement)
        XCTAssertEqual(resultDescription.attribute(forLocalName: "Label", uri: "http://ns.adobe.com/xap/1.0/")?.stringValue, "Green")
        XCTAssertTrue(updated.contains("crs:Exposure2012=\"+0.50\""))
        XCTAssertNoThrow(try XMLDocument(xmlString: updated))
    }

    func testUpdateElementFormAndMissingNamespace() throws {
        let elementForm = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/"><xmp:Rating>1</xmp:Rating></rdf:Description>
        </rdf:RDF></x:xmpmeta>
        """
        let a = try XCTUnwrap(XMPSidecar.update(existing: elementForm, with: .init(rating: 4, label: nil)))
        XCTAssertTrue(a.contains("<xmp:Rating>4</xmp:Rating>"))
        XCTAssertNoThrow(try XMLDocument(xmlString: a))

        let noNamespace = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/"/></rdf:RDF></x:xmpmeta>
        """
        let b = try XCTUnwrap(XMPSidecar.update(existing: noNamespace, with: .init(rating: -1, label: "Red")))
        let xml = try XMLDocument(xmlString: b)
        let description = try XCTUnwrap(try xml.nodes(forXPath: "//*[local-name()='Description']").first as? XMLElement)
        XCTAssertEqual(description.attribute(forLocalName: "Rating", uri: "http://ns.adobe.com/xap/1.0/")?.stringValue, "-1")
        XCTAssertEqual(description.attribute(forLocalName: "Label", uri: "http://ns.adobe.com/xap/1.0/")?.stringValue, "Red")
    }

    func testOtherPrefixForXapNamespaceIsUpdatedSafely() throws {
        let other = """
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description xmlns:xap="http://ns.adobe.com/xap/1.0/" xap:Rating="2"/></rdf:RDF>
        """
        let result = try XCTUnwrap(XMPSidecar.update(existing: other, with: .init(rating: 3, label: nil)))
        XCTAssertTrue(result.contains("xap:Rating=\"3\""))
        XCTAssertNoThrow(try XMLDocument(xmlString: result))
    }

    func testWriteCreatesUpdatesAndBacksUp() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = dir.appendingPathComponent("IMG_0001.CR3")
        let sidecar = dir.appendingPathComponent("IMG_0001.xmp")

        XCTAssertEqual(try XMPSidecar.write(photo: photo, decision: .undecided, rating: 0), .skippedNoDecision)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))

        XCTAssertEqual(try XMPSidecar.write(photo: photo, decision: .pick, rating: 3), .created)
        XCTAssertEqual(try XMPSidecar.write(photo: photo, decision: .reject, rating: 3), .updated)
        XCTAssertTrue(try String(contentsOf: sidecar, encoding: .utf8).contains("xmp:Rating=\"-1\""))
        // Every existing sidecar gets a recoverable original, including our own.
        let firstBackup = try String(contentsOf: URL(fileURLWithPath: sidecar.path + ".opencull-backup"), encoding: .utf8)
        XCTAssertTrue(firstBackup.contains("xmp:Rating=\"3\""))

        // A sidecar from another app is backed up before editing.
        let foreign = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Rating="1"/></rdf:RDF></x:xmpmeta>
        """
        try foreign.write(to: sidecar, atomically: true, encoding: .utf8)
        XCTAssertEqual(try XMPSidecar.write(photo: photo, decision: .pick, rating: 5), .updated)
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: sidecar.path + ".opencull-backup"), encoding: .utf8), firstBackup)
        XCTAssertTrue(try String(contentsOf: sidecar, encoding: .utf8).contains("xmp:Rating=\"5\""))
    }
}

// MARK: - Files

final class FileTests: XCTestCase {
    func testScannerPairsRawAndJpeg() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["IMG_0001.CR3", "IMG_0001.JPG", "IMG_0002.jpg", "notes.txt", ".hidden.jpg", "IMG_0010.NEF"] {
            try Data([0]).write(to: dir.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data([0]).write(to: dir.appendingPathComponent("sub/IMG_0003.jpg"))

        let items = try PhotoScanner.scan(folder: dir)
        XCTAssertEqual(items.map(\.fileName), ["IMG_0001.CR3", "IMG_0002.jpg", "IMG_0010.NEF"])
        XCTAssertEqual(items[0].companions.map(\.lastPathComponent), ["IMG_0001.JPG"])

        let recursive = try PhotoScanner.scan(folder: dir, recursive: true)
        XCTAssertEqual(recursive.count, 4)
    }

    func testCopyPicks() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let raw = dir.appendingPathComponent("A.CR3"), jpg = dir.appendingPathComponent("A.JPG")
        try Data([1]).write(to: raw)
        try Data([2]).write(to: jpg)
        try XMPSidecar.write(photo: raw, decision: .pick, rating: 2)
        let item = PhotoItem(url: raw, companions: [jpg])
        let destination = dir.appendingPathComponent("Picks")

        let first = Exporter.copy([item], to: destination)
        XCTAssertEqual(first.copiedPhotos, 1)
        XCTAssertTrue(first.failures.isEmpty)
        let copied = try FileManager.default.contentsOfDirectory(atPath: destination.path).sorted()
        XCTAssertEqual(copied, ["A.CR3", "A.JPG", "A.xmp"])

        let second = Exporter.copy([item], to: destination)
        XCTAssertEqual(second.copiedPhotos, 0)
        XCTAssertEqual(second.skippedExisting, 3)
    }

    func testSessionStoreRoundTrip() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("Shoot")
        let store = SessionStore(folder: folder, baseDirectory: dir.appendingPathComponent("Sessions"))
        XCTAssertEqual(store.key(for: folder.appendingPathComponent("IMG_1.CR3")), "IMG_1.CR3")

        try store.saveDecisions(["IMG_1.CR3": .init(decision: .pick, rating: 3)])
        XCTAssertEqual(store.loadDecisions()["IMG_1.CR3"], .init(decision: .pick, rating: 3))

        let a = analysis(sharpness: 123, eyes: 0.3, date: Date(timeIntervalSince1970: 5), embedding: [0.6, 0.8])
        try store.saveAnalysis(["k": a])
        XCTAssertEqual(store.loadAnalysis()["k"], a)
    }
}

// MARK: - End to end

final class AnalyzerTests: XCTestCase {
    func testAnalyzeSyntheticImage() {
        let image = cgImage(from: noiseImage(width: 320, height: 240))
        let result = PhotoAnalyzer().analyze(image: image)
        XCTAssertEqual(result.pixelWidth, 320)
        XCTAssertGreaterThan(result.sharpness, 1000)
        XCTAssertTrue(result.faces.isEmpty)
        // The feature print needs Vision's models, which restricted sandboxes may block,
        // so it is not asserted here. `opencull-cli` exercises the full Vision pipeline.
    }

    func testAnalyzeFileOnDisk() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("test.png")
        let image = cgImage(from: noiseImage(width: 300, height: 200))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let result = try PhotoAnalyzer().analyze(url: url)
        XCTAssertEqual(result.pixelWidth, 300)
        XCTAssertEqual(result.pixelHeight, 200)
        XCTAssertThrowsError(try PhotoAnalyzer().analyze(url: dir.appendingPathComponent("missing.jpg")))
    }
}
