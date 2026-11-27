import Foundation

public struct ScoringOptions: Codable, Sendable, Equatable {
    /// A face whose more-open eye is below this openness ratio counts as "eyes closed".
    public var eyesClosedThreshold: Float = 0.16
    /// Subject sharpness below this is always "blurry".
    public var blurAbsoluteThreshold: Float = 60
    /// Within a group, a shot below this fraction of the sharpest shot is "blurry".
    public var blurRelativeThreshold: Float = 0.45
    public var overexposedClipping: Float = 0.15
    public var overexposedMean: Float = 0.85
    public var underexposedMean: Float = 0.12
    public var underexposedClipping: Float = 0.40
    /// Suggest rejecting every shot in a group except the best one.
    public var rejectNonBestInGroup: Bool = true

    public init() {}
}

/// Turns measurements into issues, a 0-100 score, the best shot of each group and a
/// suggested decision. All rules are simple, documented heuristics.
public enum Scorer {
    public static func issues(for a: PhotoAnalysis, groupMaxSharpness: Float?, options: ScoringOptions) -> [Issue] {
        var result: [Issue] = []
        let relativeBlurry = groupMaxSharpness.map { $0 > 0 && a.subjectSharpness < $0 * options.blurRelativeThreshold } ?? false
        if a.subjectSharpness < options.blurAbsoluteThreshold || relativeBlurry {
            result.append(.blurry)
        }
        if hasClosedEyes(a, options: options) {
            result.append(.eyesClosed)
        }
        if a.highlightClipping > options.overexposedClipping || a.meanLuminance > options.overexposedMean {
            result.append(.overexposed)
        }
        if a.meanLuminance < options.underexposedMean && a.shadowClipping > options.underexposedClipping {
            result.append(.underexposed)
        }
        return result
    }

    public static func hasClosedEyes(_ a: PhotoAnalysis, options: ScoringOptions) -> Bool {
        a.significantFaces.contains { face in
            guard let openness = face.eyeOpenness else { return false }
            return openness < options.eyesClosedThreshold
        }
    }

    /// Quality score from 0 to 100. Only comparisons inside a group are really meaningful.
    public static func score(for a: PhotoAnalysis, groupMaxSharpness: Float?, issues: [Issue], options: ScoringOptions) -> Float {
        // Sharpness: half relative to the group's sharpest shot, half on an absolute curve
        // (0.33 at the blur threshold, approaching 1 for very sharp images).
        let relative = groupMaxSharpness.map { $0 > 0 ? min(1, a.subjectSharpness / $0) : 1 } ?? 1
        let reference = options.blurAbsoluteThreshold * 2
        let absolute = a.subjectSharpness / (a.subjectSharpness + reference)
        let sharpness = 0.5 * relative + 0.5 * absolute

        let qualities = a.significantFaces.compactMap(\.captureQuality)
        let faceQuality = qualities.isEmpty ? 0.5 : qualities.reduce(0, +) / Float(qualities.count)

        let aesthetic = a.aestheticScore.map { ($0 + 1) / 2 } ?? 0.5

        let exposurePenalty = max(0, a.highlightClipping - 0.02) * 2 + max(0, a.shadowClipping - 0.10)
        let exposure = max(0, 1 - exposurePenalty)

        var total = 0.40 * sharpness + 0.20 * faceQuality + 0.25 * aesthetic + 0.15 * exposure
        if issues.contains(.eyesClosed) { total -= 0.35 }
        if issues.contains(.blurry) { total -= 0.25 }
        return max(0, min(1, total)) * 100
    }

    /// Groups the items, scores them and fills in `groupID`, `groupSize`, `score`,
    /// `issues`, `isBestInGroup` and `suggestion`. User decisions are not touched.
    public static func evaluate(_ items: inout [PhotoItem], grouping: GroupingOptions = GroupingOptions(),
                                scoring: ScoringOptions = ScoringOptions()) {
        let analyzedIndices = items.indices.filter { items[$0].analysis != nil }
        for i in items.indices where items[i].analysis == nil {
            items[i].groupID = nil
            items[i].groupSize = 1
            items[i].score = nil
            items[i].issues = []
            items[i].isBestInGroup = false
            items[i].suggestion = .undecided
        }

        let inputs = analyzedIndices.map { i in
            Grouper.Input(name: items[i].fileName, date: items[i].analysis?.captureDate,
                          embedding: items[i].analysis?.featurePrint, layout: items[i].analysis?.layoutSignature)
        }
        let groupNumbers = Grouper.group(inputs, options: grouping)
        var members: [Int: [Int]] = [:]
        for (k, i) in analyzedIndices.enumerated() {
            members[groupNumbers[k], default: []].append(i)
        }

        for (group, indices) in members {
            let isGroup = indices.count > 1
            let maxSharpness = isGroup ? indices.compactMap { items[$0].analysis?.subjectSharpness }.max() : nil

            for i in indices {
                guard let analysis = items[i].analysis else { continue }
                let found = issues(for: analysis, groupMaxSharpness: maxSharpness, options: scoring)
                items[i].groupID = group
                items[i].groupSize = indices.count
                items[i].issues = found
                items[i].score = score(for: analysis, groupMaxSharpness: maxSharpness, issues: found, options: scoring)
                items[i].isBestInGroup = false
            }

            let best = indices.max { (items[$0].score ?? 0) < (items[$1].score ?? 0) }
            if let best, isGroup { items[best].isBestInGroup = true }

            for i in indices {
                let serious = items[i].issues.contains(.blurry) || items[i].issues.contains(.eyesClosed)
                if serious {
                    items[i].suggestion = .reject
                } else if isGroup && i != best && scoring.rejectNonBestInGroup {
                    items[i].issues.append(.duplicate)
                    items[i].suggestion = .reject
                } else {
                    items[i].suggestion = .pick
                }
            }
        }
    }
}
