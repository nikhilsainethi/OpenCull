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
        // The rectangles request supplies head pose (yaw/pitch/roll), which the eye
        // assessment needs before it can call a frontal face's closed eyes a blink.
        let rectanglesRequest = VNDetectFaceRectanglesRequest()
        let landmarksRequest = VNDetectFaceLandmarksRequest()
        do {
            try handler.perform([rectanglesRequest])
            landmarksRequest.inputFaceObservations = rectanglesRequest.results
            try handler.perform([landmarksRequest])
        }
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

            var left: Float?, right: Float?
            var leftConfidence: Float?, rightConfidence: Float?
            var leftPupil: CGPoint?, rightPupil: CGPoint?
            if let landmarks = face.landmarks {
                let leftPoints = landmarks.leftEye?.pointsInImage(imageSize: imageSize) ?? []
                let rightPoints = landmarks.rightEye?.pointsInImage(imageSize: imageSize) ?? []
                left = Self.eyeOpenness(points: leftPoints)
                right = Self.eyeOpenness(points: rightPoints)
                leftConfidence = Self.eyeLandmarkConfidence(points: leftPoints, landmarkConfidence: landmarks.confidence, faceConfidence: face.confidence)
                rightConfidence = Self.eyeLandmarkConfidence(points: rightPoints, landmarkConfidence: landmarks.confidence, faceConfidence: face.confidence)
                leftPupil = Self.pupilPosition(eyePoints: leftPoints, pupilPoints: landmarks.leftPupil?.pointsInImage(imageSize: imageSize) ?? [])
                rightPupil = Self.pupilPosition(eyePoints: rightPoints, pupilPoints: landmarks.rightPupil?.pointsInImage(imageSize: imageSize) ?? [])
            }
            // Preserve the more-open legacy value for existing clients. Decisions use
            // both supported measurements, so one hidden eye cannot be called a blink.
            let openness = [left, right].compactMap { $0 }.max()
            let sharpness = smooth.laplacianVariance(normalizedRect: topLeftBox, padding: 0.05).map { $0 * 4 }
            return FaceInfo(boundingBox: topLeftBox, captureQuality: quality, eyeOpenness: openness, sharpness: sharpness,
                leftEyeOpenness: left, rightEyeOpenness: right, leftEyeConfidence: leftConfidence, rightEyeConfidence: rightConfidence,
                yaw: face.yaw?.floatValue, pitch: face.pitch?.floatValue, roll: face.roll?.floatValue,
                leftPupilPosition: leftPupil, rightPupilPosition: rightPupil)
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
        guard let geometry = eyeGeometry(points: points) else { return nil }
        return Float((geometry.maxHeight - geometry.minHeight) / geometry.width)
    }

    /// Minimum of Vision's face/landmark support and resolved eye width. This is a
    /// conservative support score, not a probability or eye-specific Vision confidence.
    public static func eyeLandmarkConfidence(points: [CGPoint], landmarkConfidence: Float, faceConfidence: Float) -> Float? {
        guard landmarkConfidence.isFinite, faceConfidence.isFinite,
              (0...1).contains(landmarkConfidence), (0...1).contains(faceConfidence),
              let geometry = eyeGeometry(points: points) else { return nil }
        let pixelSupport = Float(min(1, geometry.width / 16))
        return min(landmarkConfidence, faceConfidence) * pixelSupport
    }

    /// A local pupil position in the eye's own oriented bounds. Missing or out-of-eye
    /// points remain unavailable, rather than inventing a centered pupil.
    public static func pupilPosition(eyePoints: [CGPoint], pupilPoints: [CGPoint]) -> CGPoint? {
        guard let geometry = eyeGeometry(points: eyePoints), !pupilPoints.isEmpty,
              pupilPoints.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let height = geometry.maxHeight - geometry.minHeight
        guard height >= 0.5 else { return nil }
        let x = pupilPoints.reduce(CGFloat(0)) { $0 + $1.x } / CGFloat(pupilPoints.count) - geometry.origin.x
        let y = pupilPoints.reduce(CGFloat(0)) { $0 + $1.y } / CGFloat(pupilPoints.count) - geometry.origin.y
        let horizontal = (x * geometry.ux + y * geometry.uy) / geometry.width
        let vertical = (-x * geometry.uy + y * geometry.ux - geometry.minHeight) / height
        guard horizontal.isFinite, vertical.isFinite, (0...1).contains(horizontal), (0...1).contains(vertical) else { return nil }
        return CGPoint(x: horizontal, y: vertical)
    }

    private static func eyeGeometry(points: [CGPoint]) -> (origin: CGPoint, ux: CGFloat, uy: CGFloat, width: CGFloat, minHeight: CGFloat, maxHeight: CGFloat)? {
        guard points.count >= 4, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
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
        guard width.isFinite, width > 0.000001 else { return nil }
        // Give both eyes a consistent image-left to image-right axis.
        if a.x > b.x || (a.x == b.x && a.y > b.y) { swap(&a, &b) }
        let ux = (b.x - a.x) / width, uy = (b.y - a.y) / width
        // Unit vector perpendicular to the corner-to-corner axis.
        let projections = points.map { -($0.x - a.x) * uy + ($0.y - a.y) * ux }
        guard let lo = projections.min(), let hi = projections.max() else { return nil }
        return (a, ux, uy, width, lo, hi)
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
