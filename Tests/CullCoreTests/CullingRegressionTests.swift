import CoreGraphics
import Foundation
import XCTest
@testable import CullCore

final class CullingRegressionTests: XCTestCase {
    private func directory() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("OpenCull-Culling-\(UUID())")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: u) }
        return u
    }

    func testSameStemDoesNotCollapseIndependentFormatsOrTwoRaws() throws {
        let d = try directory()
        for name in ["A.jpg", "A.png", "A.tif", "B.CR3", "B.NEF"] {
            try Data([0]).write(to: d.appendingPathComponent(name))
        }
        XCTAssertEqual(try PhotoScanner.scan(folder: d).count, 5)
    }

    func testUnambiguousRawJpegPairRemainsOneShot() throws {
        let d = try directory()
        for name in ["A.CR3", "A.JPG", "A.png"] { try Data([0]).write(to: d.appendingPathComponent(name)) }
        let shots = try PhotoScanner.scan(folder: d)
        XCTAssertEqual(shots.count, 2)
        XCTAssertEqual(shots.first { $0.url.pathExtension == "CR3" }?.companions.map(\.lastPathComponent), ["A.JPG"])
    }

    func testRecursiveMissingFolderThrows() throws {
        XCTAssertThrowsError(try PhotoScanner.scan(folder: try directory().appendingPathComponent("absent"), recursive: true))
    }

    func testScannerDoesNotFollowImageSymlinks() throws {
        let d = try directory()
        let target = d.appendingPathComponent("real.jpg")
        try Data([1]).write(to: target)
        try FileManager.default.createSymbolicLink(at: d.appendingPathComponent("alias.jpg"), withDestinationURL: target)
        XCTAssertEqual(try PhotoScanner.scan(folder: d).map(\.fileName), ["real.jpg"])
    }

    func testLayoutDoesNotOverrideContradictorySemanticEvidence() {
        let e0 = Embedding.normalized([Float(1), 0])!, e1 = Embedding.normalized([Float(0), 1])!
        let layout = Embedding.normalized([Float(1), 1, 0])!
        let now = Date()
        let inputs = [Grouper.Input(name: "a", date: now, embedding: e0, layout: layout),
                      Grouper.Input(name: "b", date: now.addingTimeInterval(1), embedding: e1, layout: layout)]
        XCTAssertNotEqual(Grouper.group(inputs)[0], Grouper.group(inputs)[1])
    }

    func testGroupDoesNotChainAcrossDissimilarEndpoints() {
        let now = Date()
        let inputs = (0..<4).map { i -> Grouper.Input in
            let angle = Float(i) * .pi / 6
            return .init(name: String(i), date: now.addingTimeInterval(Double(i)),
                         embedding: Embedding.normalized([cos(angle), sin(angle)]))
        }
        let groups = Grouper.group(inputs)
        XCTAssertNotEqual(groups.first, groups.last)
    }
    func testLongSteadyBurstUsesConsecutiveTimeGapNotWholeBurstDuration() {
        let now = Date()
        let same = Embedding.normalized([Float(1),0])
        let inputs = (0..<20).map { Grouper.Input(name: String($0), date: now.addingTimeInterval(Double($0)/2), embedding: same) }
        XCTAssertEqual(Set(Grouper.group(inputs)).count, 1)
    }

    func testTinyCheckerPatchDoesNotMakeFeaturelessImageAConfidentPick() {
        let w = 384, h = 384
        var pixels = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { pixels[y*w+x] = UInt8(64 + x/4) } }
        for y in 0..<32 { for x in 0..<96 { pixels[y*w+x] = (x+y)%2 == 0 ? 0 : 255 } }
        let gray = GrayImage(width: w, height: h, pixels: pixels)
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        var item = PhotoItem(url: URL(fileURLWithPath: "/tmp/patch.jpg"))
        item.analysis = PhotoAnalyzer().analyze(image: image, gray: gray)
        var items = [item]
        Scorer.evaluate(&items)
        XCTAssertNotEqual(items[0].suggestion, .pick)
    }

    func testExtremeExposureIsNotConfidentlyPicked() {
        var item = PhotoItem(url: URL(fileURLWithPath: "/tmp/clipped.jpg"))
        item.analysis = .init(pixelWidth: 100, pixelHeight: 100, captureDate: nil, sharpness: 1000,
                              subjectSharpness: 1000, meanLuminance: 0.99, highlightClipping: 0.95,
                              shadowClipping: 0, faces: [])
        var items = [item]; Scorer.evaluate(&items)
        XCTAssertNotEqual(items[0].suggestion, .pick)
    }
}
