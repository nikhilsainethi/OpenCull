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

    /// Low-pass denoising keeps sensor noise from being mistaken for focused subject detail.
    public func denoised() -> GrayImage {
        guard width > 2, height > 2 else { return self }
        var output = pixels
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let sum = Int(pixels[i-width-1]) + 2*Int(pixels[i-width]) + Int(pixels[i-width+1])
                    + 2*Int(pixels[i-1]) + 4*Int(pixels[i]) + 2*Int(pixels[i+1])
                    + Int(pixels[i+width-1]) + 2*Int(pixels[i+width]) + Int(pixels[i+width+1])
                output[i] = UInt8(sum / 16)
            }
        }
        return GrayImage(width: width, height: height, pixels: output)
    }

    /// Median high-frequency residual, reported as a diagnostic rather than a quality judgment.
    public func estimatedNoise() -> Float {
        guard width > 2, height > 2 else { return 0 }
        var residuals: [Int] = []
        let stride = max(1, min(width, height) / 300)
        for y in Swift.stride(from: 1, to: height - 1, by: stride) {
            for x in Swift.stride(from: 1, to: width - 1, by: stride) {
                let i = y * width + x
                residuals.append(abs(4*Int(pixels[i]) - Int(pixels[i-1]) - Int(pixels[i+1]) - Int(pixels[i-width]) - Int(pixels[i+width])))
            }
        }
        residuals.sort()
        return Float(residuals[residuals.count / 2]) / 3.016
    }

    /// Uses denoised detail spread over at least 20% of tiles. A tiny checker/logo patch
    /// cannot make an otherwise featureless frame look focused. Raw tiledSharpness remains
    /// available for diagnostics; recommendation thresholds use this robust measurement.
    public func robustSharpness() -> Float {
        let smooth = denoised()
        let tile = max(24, min(width, height) / 12)
        var values: [Float] = []
        for y in Swift.stride(from: 0, through: max(0, height - tile), by: tile) {
            for x in Swift.stride(from: 0, through: max(0, width - tile), by: tile) {
                values.append(smooth.laplacianVariance(x0: x, y0: y, x1: min(width, x+tile), y1: min(height, y+tile)))
            }
        }
        guard !values.isEmpty else { return 0 }
        values.sort(by: >)
        // The weakest tile among the strongest fifth enforces real spatial support.
        let index = min(values.count-1, max(0, values.count / 5))
        return values[index] * 4
    }

    /// A tiny (16x16) mean-centred brightness layout of the frame. Two frames of the same
    /// burst have nearly identical layouts even when one of them is blurred, which is
    /// where neural embeddings become unreliable.
    public func layoutSignature(gridSize: Int = 16) -> Embedding? {
        guard gridSize > 0, width >= gridSize, height >= gridSize else { return nil }
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
        let total = Float(max(1, pixels.count))
        var weighted = 0
        for (value, count) in histogram.enumerated() { weighted += value * count }
        let highlights = histogram[250...].reduce(0, +)
        let shadows = histogram[...5].reduce(0, +)
        return Exposure(mean: Float(weighted) / total / 255,
                        highlightClipping: Float(highlights) / total,
                        shadowClipping: Float(shadows) / total)
    }
}
