import Foundation

public struct ScoringOptions: Codable, Sendable, Equatable {
    public var shootingIntent: ShootingIntent = .general
    /// Eye openness threshold; new per-eye evidence also needs reliable support,
    /// frontal pose and a small uncertainty margin before a closed-eye rejection.
    public var eyesClosedThreshold: Float = 0.16
    /// Subject sharpness below this is "blurry" (reviewed under creative intent).
    public var blurAbsoluteThreshold: Float = 60
    /// Within a group, a shot below this fraction of the sharpest shot is "blurry".
    public var blurRelativeThreshold: Float = 0.45
    public var overexposedClipping: Float = 0.15
    public var overexposedMean: Float = 0.85
    public var underexposedMean: Float = 0.12
    public var underexposedClipping: Float = 0.40
    /// Suggest rejecting every shot in a group except the best one.
    public var rejectNonBestInGroup: Bool = true
    public var rejectExposureProblems: Bool = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ScoringOptions()
        shootingIntent = try c.decodeIfPresent(ShootingIntent.self, forKey: .shootingIntent) ?? d.shootingIntent
        eyesClosedThreshold = try c.decodeIfPresent(Float.self, forKey: .eyesClosedThreshold) ?? d.eyesClosedThreshold
        blurAbsoluteThreshold = try c.decodeIfPresent(Float.self, forKey: .blurAbsoluteThreshold) ?? d.blurAbsoluteThreshold
        blurRelativeThreshold = try c.decodeIfPresent(Float.self, forKey: .blurRelativeThreshold) ?? d.blurRelativeThreshold
        overexposedClipping = try c.decodeIfPresent(Float.self, forKey: .overexposedClipping) ?? d.overexposedClipping
        overexposedMean = try c.decodeIfPresent(Float.self, forKey: .overexposedMean) ?? d.overexposedMean
        underexposedMean = try c.decodeIfPresent(Float.self, forKey: .underexposedMean) ?? d.underexposedMean
        underexposedClipping = try c.decodeIfPresent(Float.self, forKey: .underexposedClipping) ?? d.underexposedClipping
        rejectNonBestInGroup = try c.decodeIfPresent(Bool.self, forKey: .rejectNonBestInGroup) ?? d.rejectNonBestInGroup
        rejectExposureProblems = try c.decodeIfPresent(Bool.self, forKey: .rejectExposureProblems) ?? d.rejectExposureProblems
    }
}

/// Turns measurements into issues, a 0-100 score, the best shot of each group and a
/// suggested decision. All rules are simple, documented heuristics.
public enum Scorer {
    private static func technicallyRejected(_ issues: [Issue], options: ScoringOptions) -> Bool {
        (issues.contains(.blurry) && options.shootingIntent != .creative) || issues.contains(.eyesClosed)
            || (options.rejectExposureProblems && (issues.contains(.overexposed) || issues.contains(.underexposed)))
    }

    private static func measurementReviewMessages(_ a: PhotoAnalysis) -> [String] {
        let focusValid = a.sharpness.isFinite && a.sharpness >= 0 && a.subjectSharpness.isFinite && a.subjectSharpness >= 0
        let exposureValid = [a.meanLuminance, a.highlightClipping, a.shadowClipping].allSatisfy { $0.isFinite && (0...1).contains($0) }
        return focusValid && exposureValid ? [] : ["Technical measurements are invalid or incomplete; inspect before accepting."]
    }

    private static func contextReviewMessages(_ a: PhotoAnalysis, issues: [Issue], options: ScoringOptions) -> [String] {
        var messages = measurementReviewMessages(a) + PeopleAssessment.reviewMessages(for: a, options: options)
        if options.shootingIntent == .creative && issues.contains(.blurry) {
            messages.append("Soft focus may be intentional for creative photography; review instead of automatically rejecting.")
        }
        return messages
    }

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
        PeopleAssessment.assessments(for: a, options: options).contains { $0.eyeState == .closed }
    }

    /// Quality score from 0 to 100. Only comparisons inside a group are really meaningful.
    public static func score(for a: PhotoAnalysis, groupMaxSharpness: Float?, issues: [Issue], options: ScoringOptions) -> Float {
        // Invalid evidence is separately routed to review; keep every public score finite.
        guard a.subjectSharpness.isFinite, a.subjectSharpness >= 0,
              [a.highlightClipping, a.shadowClipping].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return 0 }
        // Sharpness: half relative to the group's sharpest shot, half on an absolute curve
        // (0.33 at the blur threshold, approaching 1 for very sharp images).
        let relative = groupMaxSharpness.map { $0.isFinite && $0 > 0 ? min(1, a.subjectSharpness / $0) : 1 } ?? 1
        let reference = options.blurAbsoluteThreshold.isFinite && options.blurAbsoluteThreshold >= 0 ? options.blurAbsoluteThreshold * 2 : 120
        let denominator = a.subjectSharpness + reference
        let absolute = denominator > 0 ? a.subjectSharpness / denominator : 0
        let sharpness = 0.5 * relative + 0.5 * absolute

        let qualities = a.significantFaces.compactMap(\.captureQuality).filter { $0.isFinite && (0...1).contains($0) }
        let faceQuality = qualities.isEmpty ? 0.5 : qualities.reduce(0, +) / Float(qualities.count)

        let aesthetic = a.aestheticScore.flatMap { $0.isFinite && (-1...1).contains($0) ? ($0 + 1) / 2 : nil } ?? 0.5

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
                                scoring: ScoringOptions = ScoringOptions(), preference: PreferenceProfile? = nil,
                                groupOverrides: [String: String] = [:]) {
        for i in items.indices { items[i].reviewMessages = [] }
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
        var groupNumbers = Grouper.group(inputs, options: grouping)
        var nextManualGroup = (groupNumbers.max() ?? -1) + 1
        var manualNumbers: [String: Int] = [:]
        for (k, i) in analyzedIndices.enumerated() {
            if let token = groupOverrides[items[i].id] {
                if manualNumbers[token] == nil { manualNumbers[token] = nextManualGroup; nextManualGroup += 1 }
                groupNumbers[k] = manualNumbers[token]!
            }
        }
        var members: [Int: [Int]] = [:]
        for (k, i) in analyzedIndices.enumerated() {
            members[groupNumbers[k], default: []].append(i)
        }

        for (group, indices) in members {
            let isGroup = indices.count > 1
            // Incomplete/noisy measurements may be displayed for review, but must not
            // become the reference that labels another, reliable frame as weak or blurry.
            let reliable = indices.filter {
                guard let a = items[$0].analysis else { return false }
                let absoluteIssues = issues(for: a, groupMaxSharpness: nil, options: scoring)
                return items[$0].analysisError == nil && a.analysisWarnings.isEmpty
                    && contextReviewMessages(a, issues: absoluteIssues, options: scoring).isEmpty
            }
            // A closed-eye/exposure failure is not a usable alternative either. Apply
            // absolute checks before deriving relative focus, avoiding a circular test.
            let references = reliable.filter { i in
                guard let analysis = items[i].analysis else { return false }
                return !technicallyRejected(issues(for: analysis, groupMaxSharpness: nil, options: scoring), options: scoring)
            }
            let maxSharpness = isGroup ? references.compactMap { items[$0].analysis?.subjectSharpness }.max() : nil

            for i in indices {
                guard let analysis = items[i].analysis else { continue }
                let found = issues(for: analysis, groupMaxSharpness: maxSharpness, options: scoring)
                items[i].groupID = group
                items[i].groupSize = indices.count
                items[i].issues = found
                items[i].reviewMessages = contextReviewMessages(analysis, issues: found, options: scoring)
                let base = score(for: analysis, groupMaxSharpness: maxSharpness, issues: found, options: scoring)
                items[i].score = max(0, min(100, base + (preference?.adjustment(for: analysis) ?? 0)))
                items[i].isBestInGroup = false
            }

            let usable = reliable.filter { items[$0].reviewMessages.isEmpty && !technicallyRejected(items[$0].issues, options: scoring) }
            let best = usable.max { (items[$0].score ?? 0) < (items[$1].score ?? 0) }
            if let best, isGroup { items[best].isBestInGroup = true }

            for i in indices {
                let serious = technicallyRejected(items[i].issues, options: scoring)
                let warnings = items[i].analysis?.analysisWarnings ?? []
                if !warnings.isEmpty || !items[i].reviewMessages.isEmpty || items[i].analysisError != nil {
                    items[i].suggestion = .undecided
                } else if serious {
                    items[i].suggestion = .reject
                } else if isGroup && i != best && scoring.rejectNonBestInGroup {
                    let gap = (best.flatMap { items[$0].score } ?? 0) - (items[i].score ?? 0)
                    if gap < 2 {
                        items[i].suggestion = .undecided
                        items[i].reviewMessages.append("Similar alternatives are close in score; compare before choosing.")
                    } else {
                        items[i].issues.append(.duplicate)
                        items[i].suggestion = .reject
                    }
                } else {
                    items[i].suggestion = .pick
                }
            }
        }
    }

    /// Proposes up to the requested total, retaining all explicit choices and never forcing
    /// unsafe or incompletely analyzed images into the selection to meet a quota.
    @discardableResult
    public static func cullToTarget(_ items: inout [PhotoItem], count: Int) -> Int {
        let explicitPicks = items.filter { $0.decision == .pick }.count
        let capacity = max(0, count - explicitPicks)
        let eligible = items.indices.filter { i in
            guard let a = items[i].analysis else { return false }
            return items[i].decision == .undecided && !items[i].needsReview && items[i].analysisError == nil && a.analysisWarnings.isEmpty
                && !items[i].issues.contains(.blurry) && !items[i].issues.contains(.eyesClosed)
                && !items[i].issues.contains(.overexposed) && !items[i].issues.contains(.underexposed)
        }.sorted {
            if items[$0].isBestInGroup != items[$1].isBestInGroup { return items[$0].isBestInGroup }
            return (items[$0].score ?? 0) > (items[$1].score ?? 0)
        }
        let selected = Set(eligible.prefix(capacity))
        let eligibleSet = Set(eligible)
        for i in items.indices where items[i].decision == .undecided {
            if selected.contains(i) { items[i].suggestion = .pick }
            else if eligibleSet.contains(i) { items[i].suggestion = .reject }
        }
        return explicitPicks + selected.count
    }
}
