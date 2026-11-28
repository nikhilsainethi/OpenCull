import Foundation

/// A comparison of local detections at similar image positions. Each index refers to
/// the corresponding photo's original analysis.faces array, before any filtering.
public struct BurstFacePair: Equatable, Sendable {
    public let winnerFaceIndex: Int?
    public let runnerUpFaceIndex: Int?
    public let label: String
}

public struct BurstRecommendation: Equatable, Sendable {
    public let winnerID: String
    public let runnerUpID: String
    public let reason: String
    public let isCloseCall: Bool
    public let pairs: [BurstFacePair]
    public let winnerSummary: String
    public let runnerUpSummary: String
}

/// A relative recommendation for one posed burst. It never changes ratings, decisions,
/// automatic suggestions or the requirements for an unqualified Best badge.
public enum BurstRecommender {
    public static func recommend(_ items: [PhotoItem], options: ScoringOptions) -> BurstRecommendation? {
        guard options.shootingIntent == .groupPortrait, items.count >= 2 else { return nil }
        var seen = Set<String>()
        let frames = items.compactMap { item -> Frame? in
            guard let frame = Frame(item, options: options), seen.insert(frame.id).inserted else { return nil }
            return frame
        }
        guard frames.count >= 2, frames.contains(where: { $0.faces.count >= 2 }) else { return nil }

        // The upper median tolerates a passer-by in one shot yet accounts for the
        // additional detection when comparing just two shots with different coverage.
        let counts = frames.map { $0.faces.count }.sorted()
        let expected = counts[counts.count / 2] >= 2 ? counts[counts.count / 2] : counts.first { $0 >= 2 }!
        let reference = representative(frames, count: expected)
        let alignments = frames.map { matches(reference.faces, $0.faces) }
        var appearances = Array(repeating: 0, count: reference.faces.count)
        for alignment in alignments {
            for slot in alignment.indices where alignment[slot] != nil { appearances[slot] += 1 }
        }
        let recurring = appearances.indices.filter { appearances[$0] > frames.count / 2 }
        let ranked = zip(frames, alignments).map { frame, alignment in
            Ranked(frame, expected: expected, recurring: recurring, alignment: alignment)
        }.sorted { lhs, rhs in
            for axis in Axis.allCases where lhs.value(axis) != rhs.value(axis) {
                return lhs.value(axis) > rhs.value(axis)
            }
            return lhs.frame.id < rhs.frame.id
        }
        let winner = ranked[0], runner = ranked[1]
        let difference = Axis.allCases.first { winner.value($0) != runner.value($0) }
        let pairs = comparisonPairs(winner, runner, difference: difference)
        var explanation = explain(difference, winner, runner)
        if explanation.close && winner.blinks > 0 && winner.blinks == runner.blinks {
            let changed = pairs.compactMap { pair -> (EyeState, EyeState)? in
                guard let l = winner.faces.first(where: { $0.index == pair.winnerFaceIndex }),
                      let r = runner.faces.first(where: { $0.index == pair.runnerUpFaceIndex }) else { return nil }
                return (l.eyes, r.eyes)
            }
            if changed.contains(where: { $0 == .closed && $1 == .open })
                && changed.contains(where: { $0 == .open && $1 == .closed }) {
                explanation.reason += " The possible blinks are at different positions in the two shots."
            }
        }
        return BurstRecommendation(winnerID: winner.frame.id, runnerUpID: runner.frame.id,
                                   reason: explanation.reason, isCloseCall: explanation.close, pairs: pairs,
                                   winnerSummary: winner.summary, runnerUpSummary: runner.summary)
    }

    private struct Face {
        let index: Int
        let observation: FaceInfo
        var box: CGRect { observation.boundingBox }
        let eyes: EyeState
        let attention: CameraAttention
    }

    private struct Frame {
        let id: String
        let faces: [Face]
        var focus: Float
        let blurThreshold: Float
        var soft: Bool { focus < blurThreshold }
        let exposureProblem: Bool

        init?(_ item: PhotoItem, options: ScoringOptions) {
            guard item.analysisError == nil, let a = item.analysis, a.pixelWidth > 0, a.pixelHeight > 0,
                  !a.analysisWarnings.contains(where: { $0.hasPrefix(PhotoAnalyzer.faceDetectionFailurePrefix) }),
                  a.sharpness.isFinite, a.sharpness >= 0, a.subjectSharpness.isFinite, a.subjectSharpness >= 0,
                  [a.meanLuminance, a.highlightClipping, a.shadowClipping].allSatisfy({ (0...1).contains($0) }),
                  a.faces.count <= 64 else { return nil }
            id = item.id
            focus = a.subjectSharpness
            let issues = Scorer.issues(for: a, groupMaxSharpness: nil, options: options)
            blurThreshold = options.blurAbsoluteThreshold
            exposureProblem = options.rejectExposureProblems && (issues.contains(.overexposed) || issues.contains(.underexposed))
            faces = a.faces.enumerated().compactMap { index, face in
                let b = face.boundingBox
                // Include small group members in coverage but leave their eyes unknown.
                guard b.origin.x.isFinite, b.origin.y.isFinite, b.width.isFinite, b.height.isFinite,
                      b.width >= 0.025, b.height >= 0.025, b.minX >= 0, b.minY >= 0,
                      b.maxX <= 1.0001, b.maxY <= 1.0001 else { return nil }
                let evidence = PeopleAssessment.assess(face, intent: .groupPortrait, eyesClosedThreshold: options.eyesClosedThreshold)
                // A visible profile eye or a legacy aggregate cannot establish both eyes' state.
                let bilateral = !evidence.headTurned && face.leftEyeOpenness != nil && face.rightEyeOpenness != nil
                return Face(index: index, observation: face, eyes: bilateral ? evidence.eyeState : .unknown,
                            attention: evidence.cameraAttention)
            }
            guard !faces.isEmpty else { return nil }
        }
    }

    /// Sample at most seven equally spaced candidates of the expected size. A
    /// single frame with a missing member and a passer-by is a poor reference
    /// even if it sorts first. The fixed sample bounds work for large bursts.
    private static func representative(_ frames: [Frame], count: Int) -> Frame {
        let candidates = frames.filter { $0.faces.count == count }.sorted { $0.id < $1.id }
        guard candidates.count > 1 else { return candidates[0] }
        let n = min(7, candidates.count)
        let sample = (0..<n).map { candidates[$0 * (candidates.count - 1) / (n - 1)] }
        var best = sample[0], bestSupport = -1
        for candidate in sample {
            let support = sample.filter { $0.id != candidate.id }.reduce(0) { total, other in
                total + matches(candidate.faces, other.faces).compactMap { $0 }.count
            }
            if support > bestSupport { best = candidate; bestSupport = support }
        }
        return best
    }

    // Each criterion also supplies the reason for its own ordering. A per-image
    // aesthetics score or a user's previous pick must never quietly break a face tie.
    private enum Axis: CaseIterable {
        case coverage, focusFloor, exposure, openEyes, blinks, toward, away, sharpness
    }

    private struct Ranked {
        let frame: Frame
        let expected: Int
        let coverage: Int
        let faces: [Face]
        let open: Int
        let blinks: Int
        let winks: Int
        let toward: Int
        let away: Int
        let unknownAttention: Int

        init(_ frame: Frame, expected: Int, recurring: [Int], alignment: [Int?]) {
            self.expected = expected
            // Extra detections only count if aligned with a member of the reference
            // group. A background face cannot add an open eye or introduce a blink.
            faces = frame.faces.count <= expected ? frame.faces : alignment.compactMap { $0.map { frame.faces[$0] } }
            var groupFrame = frame
            if faces.count < frame.faces.count {
                // Default subject focus is the weakest significant face. An excluded
                // passer-by must not set the group's focus floor. Preserve an explicit
                // key-face focus whenever it differs from that automatic minimum.
                func weakest(_ faces: [Face]) -> Float? {
                    faces.compactMap { face in
                        guard face.observation.isSignificant, let value = face.observation.sharpness,
                              value.isFinite, value >= 0 else { return nil }
                        return value
                    }.min()
                }
                if weakest(frame.faces) == frame.focus, let retained = weakest(faces), retained > frame.focus {
                    groupFrame.focus = retained
                }
            }
            self.frame = groupFrame
            let unresolved = recurring.filter { alignment[$0] == nil }.count
            coverage = min(expected - unresolved, faces.count)
            open = faces.filter { $0.eyes == .open }.count
            blinks = faces.filter { $0.eyes == .closed }.count
            winks = faces.filter { $0.eyes == .oneEyeClosed }.count
            toward = faces.filter { $0.attention == .towardCamera }.count
            away = faces.filter { $0.attention == .awayFromCamera }.count
            unknownAttention = faces.filter { $0.attention == .unknown && $0.eyes != .closed }.count
        }

        func value(_ axis: Axis) -> Double {
            switch axis {
            case .coverage: return Double(coverage)
            case .focusFloor: return frame.soft ? 0 : 1
            case .exposure: return frame.exposureProblem ? 0 : 1
            case .openEyes: return Double(open)
            case .blinks: return -Double(blinks)
            case .toward: return Double(toward)
            case .away: return -Double(away)
            case .sharpness: return Double(frame.focus)
            }
        }

        var summary: String {
            var parts = ["\(coverage)/\(expected) face positions accounted for", "eyes appear open on \(open)"]
            if blinks > 0 { parts.append("\(blinks) possible \(blinks == 1 ? "blink" : "blinks")") }
            if winks > 0 { parts.append("\(winks) possible \(winks == 1 ? "wink" : "winks")") }
            let unknownEyes = faces.count - open - blinks - winks
            if unknownEyes > 0 { parts.append("eye state unknown on \(unknownEyes)") }
            if away > 0 { parts.append("\(away) may be looking away") }
            if unknownAttention > 0 { parts.append("attention unknown on \(unknownAttention)") }
            if toward > 0 { parts.append("\(toward) likely looking toward the camera") }
            if frame.soft { parts.append("soft subject focus") }
            if frame.exposureProblem { parts.append("possible exposure issue") }
            return parts.joined(separator: " · ")
        }
    }

    private static func explain(_ difference: Axis?, _ winner: Ranked, _ runner: Ranked) -> (reason: String, close: Bool) {
        switch difference {
        case .coverage:
            return ("Face detections account for \(winner.coverage) of \(winner.expected) group positions here and \(runner.coverage) in the runner-up. Check any unpaired faces.", true)
        case .focusFloor:
            return ("Subject focus clears the blur threshold here. The runner-up falls below it.", false)
        case .exposure:
            return ("Exposure is within your thresholds here. The runner-up has a clipping or brightness issue.", false)
        case .openEyes:
            if winner.blinks < runner.blinks {
                return ("Eyes appear open on \(winner.open) faces here and \(runner.open) in the runner-up, which has more evidence of a blink.", false)
            }
            return ("More faces have clearly open eyes here (\(winner.open) versus \(runner.open)). Inspect the other eye measurements.", true)
        case .blinks:
            return ("Both frames show \(winner.open) faces with open eyes. The runner-up has more evidence of a blink. The remaining expressions need review.", true)
        case .toward:
            return ("Pupil measurements suggest camera attention on \(winner.toward) faces here and \(runner.toward) in the runner-up. Check the eye crops.", true)
        case .away:
            return ("Pupil measurements suggest fewer people may be looking away here (\(winner.away) versus \(runner.away)). Unmeasured gaze remains unknown.", true)
        case .sharpness:
            let close = winner.frame.focus - runner.frame.focus <= max(1, winner.frame.focus * 0.15)
            return (close ? "Close call. The face assessments are similar and measured subject focus differs only slightly."
                    : "The group assessments are similar and this frame has stronger measured subject focus.", close)
        case nil:
            return ("Close call. Coverage, eye and attention counts, and measured focus are tied. Compare the expressions and choose your favorite.", true)
        }
    }

    // Match position and apparent size, never identity. Only accept mutual nearest
    // neighbours with enough separation from their respective next-best candidates.
    private struct Nearest {
        var best = Double.infinity
        var second = Double.infinity
        var index: Int?
        mutating func consider(_ candidate: Int, cost: Double) {
            if cost < best {
                second = best
                best = cost
                index = candidate
            } else if cost < second {
                second = cost
            }
        }
        var unambiguous: Int? { second - best >= 0.22 ? index : nil }
    }

    private static func matches(_ left: [Face], _ right: [Face]) -> [Int?] {
        var forward = Array(repeating: Nearest(), count: left.count)
        var reverse = Array(repeating: Nearest(), count: right.count)
        for i in left.indices {
            let a = left[i].box
            for j in right.indices {
                let b = right[j].box
                guard BurstFaceContext.isCompatible(left[i].observation, right[j].observation) else { continue }
                let widthRatio = a.width / b.width, heightRatio = a.height / b.height
                guard (0.6...1.67).contains(widthRatio), (0.6...1.67).contains(heightRatio) else { continue }
                let dx = (a.midX - b.midX) / ((a.width + b.width) / 2)
                let dy = (a.midY - b.midY) / ((a.height + b.height) / 2)
                let cost = hypot(dx, dy) + 0.25 * (abs(log(widthRatio)) + abs(log(heightRatio)))
                guard cost <= 0.85 else { continue }
                forward[i].consider(j, cost: cost)
                reverse[j].consider(i, cost: cost)
            }
        }
        return left.indices.map { i in
            guard let j = forward[i].unambiguous, reverse[j].unambiguous == i else { return nil }
            return j
        }
    }

    private static func comparisonPairs(_ winner: Ranked, _ runner: Ranked, difference: Axis?) -> [BurstFacePair] {
        let left = winner.faces, right = runner.faces
        let correspondence = matches(left, right)
        let matched = Set(correspondence.compactMap { $0 })
        var choices: [(Face?, Face?)] = left.indices.map { i in (left[i], correspondence[i].map { right[$0] }) }
        choices += right.indices.filter { !matched.contains($0) }.map { (nil, right[$0]) }
        func priority(_ l: Face?, _ r: Face?) -> Int {
            guard let l, let r else { return difference == .coverage && l != nil ? 4 : 0 }
            switch difference {
            case .openEyes, .blinks:
                if l.eyes == .open && r.eyes == .closed { return 4 }
                if l.eyes == .open && r.eyes != .open { return 3 }
                if l.eyes != .closed && r.eyes == .closed { return 3 }
            case .sharpness, .focusFloor:
                if let sharp = l.observation.sharpness, let soft = r.observation.sharpness,
                   sharp.isFinite, soft.isFinite, soft >= 0, sharp > soft, soft == runner.frame.focus { return 4 }
            case .toward, .away:
                if l.attention == .towardCamera && r.attention != .towardCamera { return 4 }
                if l.attention != .awayFromCamera && r.attention == .awayFromCamera { return 3 }
            default: break
            }
            return l.eyes != r.eyes || l.attention != r.attention ? 2 : 1
        }
        choices.sort { a, b in
            let p = priority(a.0, a.1), q = priority(b.0, b.1)
            if p != q { return p > q }
            let x = (a.0 ?? a.1)!, y = (b.0 ?? b.1)!
            if x.box.midX != y.box.midX { return x.box.midX < y.box.midX }
            if x.box.midY != y.box.midY { return x.box.midY < y.box.midY }
            if (a.0 == nil) != (b.0 == nil) { return a.0 != nil }
            return x.index < y.index
        }
        return choices.map { l, r in
            let x = (l ?? r)!.box.midX
            let position = x < 1/3 ? "Left" : x > 2/3 ? "Right" : "Center"
            let first = l.map { String($0.index + 1) } ?? "–"
            let second = r.map { String($0.index + 1) } ?? "–"
            return BurstFacePair(winnerFaceIndex: l?.index, runnerUpFaceIndex: r?.index,
                                 label: "\(position) · faces \(first) / \(second)")
        }
    }
}
