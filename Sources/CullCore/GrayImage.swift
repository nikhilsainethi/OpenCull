import CoreGraphics
import Foundation

/// An 8-bit grayscale copy of an image, used for sharpness and exposure measurements.
/// Row 0 is the top of the image.
public struct GrayImage: Sendable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height, "pixel count must equal width * height")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init?(cgImage: CGImage) {
        let w = cgImage.width, h = cgImage.height
        guard w > 0, h > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: w * h)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        self.init(width: w, height: h, pixels: buffer)
    }

    /// Variance of the 4-neighbour Laplacian inside a pixel rectangle. High values mean
    /// lots of fine detail (sharp); low values mean blur or a featureless area.
    public func laplacianVariance(x0: Int, y0: Int, x1: Int, y1: Int) -> Float {
        let xs = max(1, x0), xe = min(width - 1, x1)
        let ys = max(1, y0), ye = min(height - 1, y1)
        guard xs < xe, ys < ye else { return 0 }
        let w = width
        return pixels.withUnsafeBufferPointer { p -> Float in
            var sum: Double = 0
            var sumSquares: Double = 0
            for y in ys..<ye {
                let row = y * w
                for x in xs..<xe {
                    let i = row + x
                    let v = 4 * Int(p[i]) - Int(p[i - 1]) - Int(p[i + 1]) - Int(p[i - w]) - Int(p[i + w])
                    sum += Double(v)
                    sumSquares += Double(v * v)
                }
            }
            let n = Double((xe - xs) * (ye - ys))
            let mean = sum / n
            return Float(max(0, sumSquares / n - mean * mean))
        }
    }

    /// Laplacian variance inside a normalized rectangle (0...1, origin top-left), expanded by `padding`.
    public func laplacianVariance(normalizedRect r: CGRect, padding: CGFloat = 0) -> Float? {
        let padded = r.insetBy(dx: -r.width * padding, dy: -r.height * padding)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !padded.isNull else { return nil }
        let x0 = Int(padded.minX * CGFloat(width)), x1 = Int(padded.maxX * CGFloat(width))
        let y0 = Int(padded.minY * CGFloat(height)), y1 = Int(padded.maxY * CGFloat(height))
        guard x1 - x0 >= 24, y1 - y0 >= 24 else { return nil }
        return laplacianVariance(x0: x0, y0: y0, x1: x1, y1: y1)
    }

    /// Splits the image into tiles and averages the sharpness of the sharpest 5% of them.
    /// Using the sharpest tiles (instead of the whole frame) means a portrait with a sharp
    /// subject and a deliberately blurred background still counts as sharp.
    public func tiledSharpness() -> Float {
        let tile = max(32, min(width, height) / 12)
        var values: [Float] = []
        var y = 0
        while y + tile <= height {
            var x = 0
            while x + tile <= width {
                values.append(laplacianVariance(x0: x, y0: y, x1: x + tile, y1: y + tile))
                x += tile
            }
            y += tile
        }
        if values.isEmpty { return laplacianVariance(x0: 0, y0: 0, x1: width, y1: height) }
        values.sort(by: >)
        let count = min(values.count, max(3, values.count / 20))
        return values.prefix(count).reduce(0, +) / Float(count)
    }

    /// A tiny (16x16) mean-centred brightness layout of the frame. Two frames of the same
    /// burst have nearly identical layouts even when one of them is blurred, which is
    /// where neural embeddings become unreliable.
    public func layoutSignature(gridSize: Int = 16) -> Embedding? {
        guard width >= gridSize, height >= gridSize else { return nil }
        var cells = [Float](repeating: 0, count: gridSize * gridSize)
        pixels.withUnsafeBufferPointer { p in
            for gy in 0..<gridSize {
                let y0 = gy * height / gridSize, y1 = (gy + 1) * height / gridSize
                for gx in 0..<gridSize {
                    let x0 = gx * width / gridSize, x1 = (gx + 1) * width / gridSize
                    var sum = 0
                    for y in y0..<y1 {
                        let row = y * width
                        for x in x0..<x1 { sum += Int(p[row + x]) }
                    }
                    cells[gy * gridSize + gx] = Float(sum) / Float(max(1, (y1 - y0) * (x1 - x0)))
                }
            }
        }
        let mean = cells.reduce(0, +) / Float(cells.count)
        return Embedding.normalized(cells.map { $0 - mean })
    }

    public struct Exposure: Sendable, Equatable {
        public var mean: Float
        public var highlightClipping: Float
        public var shadowClipping: Float
    }

    /// Mean brightness and the fraction of near-white (>= 250) and near-black (<= 5) pixels.
    public func exposure() -> Exposure {
        var histogram = [Int](repeating: 0, count: 256)
        pixels.withUnsafeBufferPointer { p in
            for v in p { histogram[Int(v)] += 1 }
        }
        let total = Float(pixels.count)
        var weighted = 0
        for (value, count) in histogram.enumerated() { weighted += value * count }
        let highlights = histogram[250...].reduce(0, +)
        let shadows = histogram[...5].reduce(0, +)
        return Exposure(mean: Float(weighted) / total / 255,
                        highlightClipping: Float(highlights) / total,
                        shadowClipping: Float(shadows) / total)
    }
}
