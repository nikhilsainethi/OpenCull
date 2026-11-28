import CoreGraphics
import XCTest
@testable import CullCore

final class BurstFaceContextTests: XCTestCase {
    func testSamplesBelowTheOrientedFaceAndAbstainsAtImageEdge() throws {
        let size = 96
        var pixels = [UInt8]()
        for y in 0..<size {
            for _ in 0..<size { pixels += y < size / 2 ? [255, 0, 0, 255] : [0, 0, 255, 255] }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let sampler = try XCTUnwrap(BurstContextSampler(image: image))
        let color = try XCTUnwrap(sampler.color(below: CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.2)))
        XCTAssertGreaterThan(color.blue, 245)
        XCTAssertLessThan(color.red, 10)
        XCTAssertNil(sampler.color(below: CGRect(x: 0.4, y: 0.8, width: 0.2, height: 0.2)))
        XCTAssertNil(sampler.color(below: .null))
    }

    func testOnlyStrongContextConflictsVetoCorrespondence() throws {
        var red = FaceInfo(boundingBox: CGRect(x: 0.2, y: 0.3, width: 0.2, height: 0.2))
        let unknown = red
        red.surroundingColor = BurstFaceContext(red: 230, green: 35, blue: 35)
        var blue = red
        blue.surroundingColor = BurstFaceContext(red: 25, green: 40, blue: 210)
        var darker = red
        darker.surroundingColor = BurstFaceContext(red: 180, green: 12, blue: 12)
        XCTAssertFalse(BurstFaceContext.isCompatible(red, blue))
        XCTAssertTrue(BurstFaceContext.isCompatible(red, darker))
        XCTAssertTrue(BurstFaceContext.isCompatible(red, unknown))
        let roundTrip = try JSONDecoder().decode(FaceInfo.self, from: JSONEncoder().encode(red))
        XCTAssertEqual(roundTrip, red)
    }
}
