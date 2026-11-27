import CoreGraphics
import Foundation
import Vision

public struct AnalyzerOptions: Sendable, Equatable {
    /// Longest side, in pixels, of the image used for analysis.
    public var analysisSize: Int = 1600
    public init() {}
}

public enum AnalysisError: Error, LocalizedError {
    case cannotDecode(URL)

    public var errorDescription: String? {
        switch self {
        case .cannotDecode(let url): return "Could not decode \(url.lastPathComponent)."
        }
    }
}

/// Measures one photo: sharpness, exposure, faces/eyes, aesthetics and a similarity embedding.
/// Everything runs on-device with ImageIO and Apple's Vision framework.
public struct PhotoAnalyzer: Sendable {
    public var options: AnalyzerOptions

    public init(options: AnalyzerOptions = AnalyzerOptions()) {
        self.options = options
    }

    /// Analyzes `url`. If it cannot be decoded (e.g. a RAW format ImageIO does not support),
    /// the `fallback` file (typically the camera JPEG of a RAW+JPEG pair) is used instead.
    public func analyze(url: URL, fallback: URL? = nil) throws -> PhotoAnalysis {
        var source = url
        var image = ImageLoader.loadImage(url: url, maxPixelSize: options.analysisSize)
        if image == nil, let fallback {
            image = ImageLoader.loadImage(url: fallback, maxPixelSize: options.analysisSize)
            source = fallback
        }
        guard let image, let gray = GrayImage(cgImage: image) else { throw AnalysisError.cannotDecode(url) }
        let metadata = ImageLoader.metadata(url: url) ?? ImageLoader.metadata(url: source)
        var analysis = analyze(image: image, gray: gray, metadata: metadata)
        if ImageLoader.isRaw(url), !ImageLoader.supportsFullRawDecoding(url: url) {
            analysis.analysisWarnings.insert("Full-resolution RAW decoding is unavailable for this camera on this Mac. Analysis uses a preview or companion image; inspect it manually. Native RAW editing is unavailable.", at: 0)
        }
        return analysis
    }

    /// Analyzes an already decoded, upright image.
    public func analyze(image: CGImage, gray providedGray: GrayImage? = nil, metadata: ImageLoader.Metadata? = nil) -> PhotoAnalysis {
        let gray = providedGray ?? GrayImage(cgImage: image) ?? GrayImage(width: 1, height: 1, pixels: [0])
        let sharpness = gray.robustSharpness()
        let exposure = gray.exposure()
        let noise = gray.estimatedNoise()
        var warnings: [String] = []
        if noise > 10 { warnings.append("High image noise or fine texture: inspect focus at 100% before accepting.") }

        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        let faces = detectFaces(handler: handler, imageSize: CGSize(width: image.width, height: image.height), gray: gray, warnings: &warnings)

        // Keep a soft second significant person from being hidden by a sharper larger face.
        let subjectSharpness = faces.filter(\.isSignificant).compactMap(\.sharpness).min() ?? sharpness

        var aesthetic: Float?
        var utility: Bool?
        if #available(macOS 15.0, *) {
            let request = VNCalculateImageAestheticsScoresRequest()
            do {
                try handler.perform([request])
                if let result = request.results?.first { aesthetic = result.overallScore; utility = result.isUtility }
                else { warnings.append("Aesthetics analysis returned no result.") }
            } catch { warnings.append("Aesthetics analysis unavailable: \(error.localizedDescription)") }
        }

        var embedding: Embedding?
        let printRequest = VNGenerateImageFeaturePrintRequest()
        printRequest.imageCropAndScaleOption = .scaleFill
        do {
            try handler.perform([printRequest])
            if let result = printRequest.results?.first { embedding = Self.embedding(from: result) }
            if embedding == nil { warnings.append("Similarity analysis returned no usable feature print.") }
        } catch { warnings.append("Similarity analysis unavailable: \(error.localizedDescription)") }
        let classify = VNClassifyImageRequest()
        var labels: [String] = []
        do {
            try handler.perform([classify])
            labels = (classify.results ?? []).filter { $0.confidence >= 0.12 }.prefix(12).map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
        } catch { warnings.append("Search labels unavailable: \(error.localizedDescription)") }

        return PhotoAnalysis(
            pixelWidth: metadata?.pixelWidth ?? image.width,
            pixelHeight: metadata?.pixelHeight ?? image.height,
            captureDate: metadata?.captureDate,
            sharpness: sharpness,
            subjectSharpness: subjectSharpness,
            meanLuminance: exposure.mean,
            highlightClipping: exposure.highlightClipping,
            shadowClipping: exposure.shadowClipping,
            faces: faces,
            aestheticScore: aesthetic,
            isUtility: utility,
            featurePrint: embedding,
            layoutSignature: gray.layoutSignature(), analysisWarnings: warnings, labels: labels, noiseLevel: noise
        )
    }

    // MARK: - Faces

    private func detectFaces(handler: VNImageRequestHandler, imageSize: CGSize, gray: GrayImage, warnings: inout [String]) -> [FaceInfo] {
        let landmarksRequest = VNDetectFaceLandmarksRequest()
        do { try handler.perform([landmarksRequest]) }
        catch { warnings.append("Face analysis unavailable: \(error.localizedDescription)"); return [] }
        guard let observations = landmarksRequest.results, !observations.isEmpty else { return [] }

        let qualityRequest = VNDetectFaceCaptureQualityRequest()
        qualityRequest.inputFaceObservations = observations
        do { try handler.perform([qualityRequest]) }
        catch { warnings.append("Face quality unavailable: \(error.localizedDescription)") }
        let qualityResults = qualityRequest.results ?? []
        let smooth = gray.denoised()

        return observations.map { face in
            let box = face.boundingBox // normalized, origin bottom-left
            let topLeftBox = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
            let quality = qualityResults
                .max { Self.overlap($0.boundingBox, box) < Self.overlap($1.boundingBox, box) }
                .flatMap { Self.overlap($0.boundingBox, box) > 0.5 ? $0.faceCaptureQuality : nil }

            var openness: Float?
            if let landmarks = face.landmarks {
                let left = Self.eyeOpenness(landmarks.leftEye, imageSize: imageSize)
                let right = Self.eyeOpenness(landmarks.rightEye, imageSize: imageSize)
                // Use the more open eye so a hidden or badly located eye (profile shots)
                // does not cause a false "eyes closed" result.
                switch (left, right) {
                case let (l?, r?): openness = max(l, r)
                case let (l?, nil): openness = l
                case let (nil, r?): openness = r
                default: openness = nil
                }
            }
            let sharpness = smooth.laplacianVariance(normalizedRect: topLeftBox, padding: 0.05).map { $0 * 4 }
            return FaceInfo(boundingBox: topLeftBox, captureQuality: quality, eyeOpenness: openness, sharpness: sharpness)
        }
    }

    /// Eye opening relative to eye width, measured along the eye's own axis so head tilt
    /// does not change the result. Open eyes are typically around 0.25-0.4, closed eyes
    /// much lower.
    static func eyeOpenness(_ region: VNFaceLandmarkRegion2D?, imageSize: CGSize) -> Float? {
        guard let region, region.pointCount >= 4 else { return nil }
        let points = region.pointsInImage(imageSize: imageSize)
        return eyeOpenness(points: points)
    }

    /// Geometry behind `eyeOpenness`, separated for testing.
    public static func eyeOpenness(points: [CGPoint]) -> Float? {
        guard points.count >= 4 else { return nil }
        // The two farthest-apart points are the eye corners.
        var a = points[0], b = points[1], best: CGFloat = -1
        for i in 0..<points.count {
            for j in (i + 1)..<points.count {
                let dx = points[i].x - points[j].x, dy = points[i].y - points[j].y
                let d = dx * dx + dy * dy
                if d > best { best = d; a = points[i]; b = points[j] }
            }
        }
        let width = best.squareRoot()
        guard width > 0 else { return nil }
        // Unit vector perpendicular to the corner-to-corner axis.
        let nx = -(b.y - a.y) / width, ny = (b.x - a.x) / width
        let projections = points.map { ($0.x - a.x) * nx + ($0.y - a.y) * ny }
        guard let lo = projections.min(), let hi = projections.max() else { return nil }
        return Float((hi - lo) / width)
    }

    /// Intersection over union of two rectangles.
    static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        let i = intersection.width * intersection.height
        let u = a.width * a.height + b.width * b.height - i
        return u > 0 ? i / u : 0
    }

    // MARK: - Embedding

    static func embedding(from observation: VNFeaturePrintObservation) -> Embedding? {
        let count = observation.elementCount
        let data = observation.data
        let values: [Float]
        switch observation.elementType {
        case .float:
            guard data.count >= count * MemoryLayout<Float>.size else { return nil }
            values = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(count)) }
        case .double:
            guard data.count >= count * MemoryLayout<Double>.size else { return nil }
            values = data.withUnsafeBytes { $0.bindMemory(to: Double.self).prefix(count).map { Float($0) } }
        default:
            return nil
        }
        return Embedding.normalized(values)
    }
}
