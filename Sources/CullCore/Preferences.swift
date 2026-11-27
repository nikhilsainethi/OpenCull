import Foundation

/// A small local preference model learned only from explicit user decisions. It compares
/// regularized feature centroids, stays neutral until both classes have enough examples,
/// and can adjust rankings by at most ten points. It never overrides technical safeguards.
public struct PreferenceProfile: Codable, Sendable, Equatable {
    private struct Sample: Codable, Sendable, Equatable {
        var id: String
        var features: [Float]
        var picked: Bool
        var weight: Float?
    }
    private enum CodingKeys: String, CodingKey { case samples }
    private var samples: [Sample] = []
    private var positiveMean: [Float] = []
    private var negativeMean: [Float] = []
    private var positiveCount = 0
    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try c.decodeIfPresent([Sample].self, forKey: .samples) ?? []
        guard decoded.allSatisfy({ $0.features.count == 6 && $0.features.allSatisfy(\.isFinite)
            && ($0.weight == nil || ($0.weight!.isFinite && (1...1.5).contains($0.weight!))) }) else {
            throw DecodingError.dataCorruptedError(forKey: .samples, in: c, debugDescription: "Invalid local preference feature vector.")
        }
        var ids = Set<String>()
        samples = decoded.reversed().filter { ids.insert($0.id).inserted }.prefix(600).reversed()
        rebuild()
    }
    public var sampleCount: Int { samples.count }
    public var pickCount: Int { positiveCount }
    public var rejectCount: Int { sampleCount - pickCount }
    public var isReady: Bool { sampleCount >= 12 && pickCount >= 4 && rejectCount >= 4 }

    /// A stable photo ID replaces earlier evidence for that photo, including removing it
    /// when the decision is cleared. Unidentified samples are unique examples.
    public mutating func record(analysis: PhotoAnalysis, decision: Decision, rating: Int = 0, sampleID: String? = nil) {
        let id = sampleID ?? UUID().uuidString
        defer { rebuild() }
        samples.removeAll { $0.id == id }
        guard decision != .undecided else { return }
        let features = Self.features(analysis)
        guard features.allSatisfy(\.isFinite), analysis.analysisWarnings.isEmpty else { return }
        let weight: Float = decision == .pick ? 1 + Float(max(0,min(5,rating))) / 10 : 1
        samples.append(Sample(id: id, features: features, picked: decision == .pick, weight: weight))
        if samples.count > 600 { samples.removeFirst(samples.count - 600) }
    }

    public func adjustment(for analysis: PhotoAnalysis) -> Float {
        guard isReady else { return 0 }
        let vector = Self.features(analysis)
        guard vector.allSatisfy(\.isFinite) else { return 0 }
        let p = positiveMean, n = negativeMean
        var numerator: Float = 0, denominator: Float = 0.1
        for i in vector.indices {
            let difference = p[i] - n[i]
            let midpoint = (p[i] + n[i]) / 2
            numerator += difference * (vector[i] - midpoint)
            denominator += difference * difference / 2
        }
        // Smooth bounded response plus evidence shrinkage prevents a few examples dominating.
        let strength = min(1, Float(samples.count) / 40)
        return 10 * strength * tanh(numerator / denominator)
    }

    private mutating func rebuild() {
        let positives = samples.filter(\.picked), negatives = samples.filter { !$0.picked }
        positiveCount = positives.count
        positiveMean = Self.mean(positives)
        negativeMean = Self.mean(negatives)
    }

    private static func features(_ a: PhotoAnalysis) -> [Float] {
        let qualities = a.significantFaces.compactMap(\.captureQuality)
        let quality = qualities.isEmpty ? Float(0.5) : qualities.reduce(0,+) / Float(qualities.count)
        let openness = a.significantFaces.compactMap(\.eyeOpenness).min() ?? 0.3
        return [min(1, max(0, log1p(max(0, a.subjectSharpness)) / log(2001))),
                quality, ((a.aestheticScore ?? 0) + 1) / 2,
                1-min(1, a.highlightClipping+a.shadowClipping),
                min(1, max(0, openness/0.4)), min(1, max(0, a.meanLuminance))]
    }
    private static func mean(_ samples: [Sample]) -> [Float] {
        guard let first = samples.first else { return [] }
        let total = samples.reduce(Float(0)) { $0 + ($1.weight ?? 1) }
        return first.features.indices.map { i in samples.reduce(Float(0)) { $0 + $1.features[i] * ($1.weight ?? 1) } / total }
    }
}
