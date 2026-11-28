import CoreGraphics
import Foundation

/// The culling decision for a photo, either suggested by the analyzer or made by the user.
public enum Decision: String, Codable, Sendable, CaseIterable {
    case undecided
    case pick
    case reject
}

/// A problem detected in a photo.
public enum Issue: String, Codable, Sendable, CaseIterable, Comparable {
    case blurry
    case eyesClosed
    case overexposed
    case underexposed
    case duplicate

    public var label: String {
        switch self {
        case .blurry: return "Out of focus / blurry"
        case .eyesClosed: return "Eyes closed"
        case .overexposed: return "Overexposed"
        case .underexposed: return "Underexposed"
        case .duplicate: return "Weaker shot in a similar group"
        }
    }

    public var symbolName: String {
        switch self {
        case .blurry: return "scope"
        case .eyesClosed: return "eye.slash"
        case .overexposed: return "sun.max.fill"
        case .underexposed: return "moon.fill"
        case .duplicate: return "square.on.square"
        }
    }

    public static func < (lhs: Issue, rhs: Issue) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// Facts about one detected face.
public struct FaceInfo: Codable, Sendable, Equatable {
    /// Normalized bounding box (0...1), origin at the TOP-left of the image.
    public var boundingBox: CGRect
    /// Apple Vision face capture quality (0...1). Only meaningful when compared between
    /// shots of the same person.
    public var captureQuality: Float?
    /// Eye openness ratio (eye height / eye width) of the more open eye, or nil when
    /// eye landmarks were not found.
    public var eyeOpenness: Float?
    /// Laplacian sharpness measured inside the face box.
    public var sharpness: Float?

    /// Individual landmark ratios. Unlike the legacy aggregate, these retain a wink.
    public var leftEyeOpenness: Float?
    public var rightEyeOpenness: Float?
    /// Landmark/geometry support (0...1), not a calibrated likelihood of closed eyes.
    /// Nil means that measurement reliability was not established.
    public var leftEyeConfidence: Float?
    public var rightEyeConfidence: Float?
    /// Vision head orientation in radians. Head direction is not eye gaze.
    public var yaw: Float?
    public var pitch: Float?
    public var roll: Float?
    /// Pupil location inside oriented eye bounds, with (0.5, 0.5) at the center.
    /// Missing pupils, profiles and low support must remain unknown attention.
    public var leftPupilPosition: CGPoint?
    public var rightPupilPosition: CGPoint?
    public var surroundingColor: BurstFaceContext?

    public init(boundingBox: CGRect, captureQuality: Float? = nil, eyeOpenness: Float? = nil, sharpness: Float? = nil,
                leftEyeOpenness: Float? = nil, rightEyeOpenness: Float? = nil,
                leftEyeConfidence: Float? = nil, rightEyeConfidence: Float? = nil,
                yaw: Float? = nil, pitch: Float? = nil, roll: Float? = nil,
                leftPupilPosition: CGPoint? = nil, rightPupilPosition: CGPoint? = nil, surroundingColor: BurstFaceContext? = nil) {
        self.boundingBox = boundingBox
        self.captureQuality = captureQuality
        self.eyeOpenness = eyeOpenness ?? [leftEyeOpenness, rightEyeOpenness].compactMap { $0 }.filter { $0.isFinite && (0...1).contains($0) }.max()
        self.sharpness = sharpness
        self.leftEyeOpenness = leftEyeOpenness
        self.rightEyeOpenness = rightEyeOpenness
        self.leftEyeConfidence = leftEyeConfidence
        self.rightEyeConfidence = rightEyeConfidence
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
        self.leftPupilPosition = leftPupilPosition
        self.rightPupilPosition = rightPupilPosition
        self.surroundingColor = surroundingColor
    }

    /// Faces smaller than this (as a fraction of image width) are too small for reliable
    /// eye and sharpness measurements, so they are ignored for those checks.
    public static let minimumSignificantWidth: CGFloat = 0.05

    public var isSignificant: Bool {
        let b = boundingBox
        return b.origin.x.isFinite && b.origin.y.isFinite && b.width.isFinite && b.height.isFinite
            && b.minX >= 0 && b.minY >= 0 && b.maxX <= 1.0001 && b.maxY <= 1.0001
            && b.width >= Self.minimumSignificantWidth && b.height > 0
    }
}

/// Everything measured about one photo. Expensive to compute, so it is cached.
public struct PhotoAnalysis: Codable, Sendable, Equatable {
    /// Bump this when the analysis changes so old cached results are recomputed.
    public static let currentVersion = 5

    public var version: Int = PhotoAnalysis.currentVersion
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var captureDate: Date?
    /// Denoised focus detail with minimum spatial tile support (not a calibrated probability).
    public var sharpness: Float
    /// Weakest measurable significant face focus, otherwise the robust whole-frame measure.
    public var subjectSharpness: Float
    /// Mean luminance, 0...1.
    public var meanLuminance: Float
    /// Fraction of pixels that are nearly pure white.
    public var highlightClipping: Float
    /// Fraction of pixels that are nearly pure black.
    public var shadowClipping: Float
    public var faces: [FaceInfo]
    /// Apple Vision aesthetics score (-1...1). macOS 15 or later only.
    public var aestheticScore: Float?
    /// Apple Vision's "utility image" flag (screenshots, documents, receipts). macOS 15+ only.
    public var isUtility: Bool?
    /// L2-normalized image embedding used to find similar shots.
    public var featurePrint: Embedding?
    /// Low-resolution brightness layout, robust to blur. Used together with `featurePrint`.
    public var layoutSignature: Embedding?
    /// Explicit diagnostics; an unavailable Vision measurement is not a negative detection.
    public var analysisWarnings: [String]
    /// Local Vision classification labels used by text search.
    public var labels: [String]
    public var noiseLevel: Float?

    public init(pixelWidth: Int, pixelHeight: Int, captureDate: Date?, sharpness: Float, subjectSharpness: Float,
                meanLuminance: Float, highlightClipping: Float, shadowClipping: Float, faces: [FaceInfo],
                aestheticScore: Float? = nil, isUtility: Bool? = nil, featurePrint: Embedding? = nil,
                layoutSignature: Embedding? = nil, analysisWarnings: [String] = [], labels: [String] = [], noiseLevel: Float? = nil) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.captureDate = captureDate
        self.sharpness = sharpness
        self.subjectSharpness = subjectSharpness
        self.meanLuminance = meanLuminance
        self.highlightClipping = highlightClipping
        self.shadowClipping = shadowClipping
        self.faces = faces
        self.aestheticScore = aestheticScore
        self.isUtility = isUtility
        self.featurePrint = featurePrint
        self.layoutSignature = layoutSignature
        self.analysisWarnings = analysisWarnings
        self.labels = labels
        self.noiseLevel = noiseLevel
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(pixelWidth: try c.decode(Int.self, forKey: .pixelWidth), pixelHeight: try c.decode(Int.self, forKey: .pixelHeight),
                  captureDate: try c.decodeIfPresent(Date.self, forKey: .captureDate), sharpness: try c.decode(Float.self, forKey: .sharpness),
                  subjectSharpness: try c.decode(Float.self, forKey: .subjectSharpness), meanLuminance: try c.decode(Float.self, forKey: .meanLuminance),
                  highlightClipping: try c.decode(Float.self, forKey: .highlightClipping), shadowClipping: try c.decode(Float.self, forKey: .shadowClipping),
                  faces: try c.decode([FaceInfo].self, forKey: .faces), aestheticScore: try c.decodeIfPresent(Float.self, forKey: .aestheticScore),
                  isUtility: try c.decodeIfPresent(Bool.self, forKey: .isUtility), featurePrint: try c.decodeIfPresent(Embedding.self, forKey: .featurePrint),
                  layoutSignature: try c.decodeIfPresent(Embedding.self, forKey: .layoutSignature),
                  analysisWarnings: try c.decodeIfPresent([String].self, forKey: .analysisWarnings) ?? [],
                  labels: try c.decodeIfPresent([String].self, forKey: .labels) ?? [], noiseLevel: try c.decodeIfPresent(Float.self, forKey: .noiseLevel))
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
    }

    public var significantFaces: [FaceInfo] { faces.filter(\.isSignificant) }
}

/// One photo in the library. A RAW+JPEG pair with the same name is treated as one photo.
public struct PhotoItem: Identifiable, Sendable, Equatable {
    /// Absolute path of the primary file.
    public var id: String { url.path }
    /// Primary file (the RAW when a RAW+JPEG pair exists).
    public let url: URL
    /// Other files that belong to the same shot (e.g. the JPEG of a RAW+JPEG pair).
    public let companions: [URL]
    public let fileSize: Int64
    public let modificationDate: Date

    public var analysis: PhotoAnalysis?
    public var analysisError: String?

    // Results of grouping and scoring.
    public var groupID: Int?
    public var groupSize: Int = 1
    public var score: Float?
    public var isBestInGroup: Bool = false
    public var issues: [Issue] = []
    public var suggestion: Decision = .undecided
    public var reviewMessages: [String] = []

    // The user's choices.
    public var decision: Decision = .undecided
    public var rating: Int = 0

    public init(url: URL, companions: [URL] = [], fileSize: Int64 = 0, modificationDate: Date = Date(timeIntervalSince1970: 0)) {
        self.url = url
        self.companions = companions
        self.fileSize = fileSize
        self.modificationDate = modificationDate
    }

    public var fileName: String { url.lastPathComponent }

    /// Every file belonging to this shot.
    public var allFiles: [URL] { [url] + companions }

    public var reviewReasons: [String] {
        if let analysisError { return [analysisError] }
        guard let analysis else { return ["Analysis pending"] }
        return analysis.analysisWarnings + reviewMessages
    }
    public var needsReview: Bool { analysis == nil || !reviewReasons.isEmpty || suggestion == .undecided }

    /// Identifies this exact file version; cached analysis is reused only when it matches.
    public var cacheKey: String { "\(url.path)|\(fileSize)|\(modificationDate.timeIntervalSince1970)" }
}
