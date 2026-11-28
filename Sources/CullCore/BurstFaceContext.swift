import CoreGraphics
import Foundation

/// A single color sampled below a face, used only to veto unlikely spatial
/// matches. It encodes neither facial detail nor a person's identity.
public struct BurstFaceContext: Codable, Equatable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static func isCompatible(_ first: FaceInfo, _ second: FaceInfo) -> Bool {
        guard let a = first.surroundingColor, let b = second.surroundingColor else { return true }
        // Subtracting channel shifts removes pure brightness changes. Veto only a
        // pronounced color change, such as red clothing at a previously blue spot.
        let dr = Int(a.red) - Int(b.red), dg = Int(a.green) - Int(b.green), db = Int(a.blue) - Int(b.blue)
        return max(dr, dg, db) - min(dr, dg, db) < 110
    }
}

struct BurstContextSampler {
    private static let side = 96
    private let pixels: [UInt8]

    init?(image: CGImage) {
        let side = Self.side
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                    bytesPerRow: side * 4, space: space,
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        pixels = bytes
    }

    func color(below box: CGRect) -> BurstFaceContext? {
        let region = CGRect(x: box.midX - box.width * 0.35, y: box.maxY + box.height * 0.20,
                            width: box.width * 0.70, height: box.height * 0.55)
        guard !region.isEmpty, !region.isInfinite, region.minX >= 0, region.minY >= 0,
              region.maxX <= 1, region.maxY <= 1 else { return nil }
        let side = CGFloat(Self.side)
        let xs = Int((region.minX * side).rounded(.up))..<Int((region.maxX * side).rounded(.up))
        let ys = Int((region.minY * side).rounded(.up))..<Int((region.maxY * side).rounded(.up))
        guard xs.count >= 2, ys.count >= 2 else { return nil }
        var r = 0, g = 0, b = 0
        for y in ys {
            for x in xs {
                let offset = (y * Self.side + x) * 4
                r += Int(pixels[offset])
                g += Int(pixels[offset + 1])
                b += Int(pixels[offset + 2])
            }
        }
        let count = xs.count * ys.count
        return BurstFaceContext(red: UInt8(r / count), green: UInt8(g / count), blue: UInt8(b / count))
    }
}
