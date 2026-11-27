import CoreGraphics
import Foundation

/// Aesthetic intent changes which measurements need a person's review.
public enum ShootingIntent: String, Codable, Sendable, CaseIterable, Identifiable {
    case general, posedPortrait, groupPortrait, candid, creative

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .general: return "General photography"
        case .posedPortrait: return "Posed portrait"
        case .groupPortrait: return "Posed group"
        case .candid: return "Candid / documentary"
        case .creative: return "Creative / intentional blur"
        }
    }
    public var help: String {
        switch self {
        case .general: return "Check focus and clear blinks; camera attention is neutral."
        case .posedPortrait: return "Review uncertain eyes or camera attention before accepting a posed portrait."
        case .groupPortrait: return "Check every significant face and review uncertain camera attention."
        case .candid: return "Looking away is neutral; focus and clear blinks still receive technical checks."
        case .creative: return "Soft focus may be intentional and requires review instead of automatic rejection."
        }
    }
    public var requiresCameraAttention: Bool { self == .posedPortrait || self == .groupPortrait }
}

public enum EyeState: String, Codable, Sendable {
    case open, closed, oneEyeClosed, unknown
}

public enum CameraAttention: String, Codable, Sendable {
    case towardCamera, awayFromCamera, unknown
}

/// Descriptions of local geometric evidence, not biometric identity or calibrated gaze.
public struct FaceAssessment: Sendable, Equatable {
    public var eyeState: EyeState
    public var cameraAttention: CameraAttention
    public var headTurned: Bool
    public var eyeDescription: String
    public var attentionDescription: String
    public var headPoseDescription: String
    public var eyeConfidenceDescription: String
    public var attentionConfidenceDescription: String
    public var reviewMessages: [String]
    public var summary: String { [eyeDescription, headPoseDescription, attentionDescription].joined(separator: "; ") }
}

/// Conservative pure rules shared by scoring and per-face UI explanations.
public enum PeopleAssessment {
    public static let minimumEyeConfidence: Float = 0.65

    private static func validRatio(_ value: Float?) -> Float? {
        guard let value, value.isFinite, (0...1).contains(value) else { return nil }
        return value
    }

    private static func supported(_ value: Float?, confidence: Float?) -> Float? {
        guard let confidence = validRatio(confidence), confidence >= minimumEyeConfidence else { return nil }
        return validRatio(value)
    }

    private static func validAngle(_ value: Float?) -> Float? {
        guard let value, value.isFinite, abs(value) <= .pi else { return nil }
        return value
    }

    private static func validPupil(_ point: CGPoint?) -> CGPoint? {
        guard let point, point.x.isFinite, point.y.isFinite,
              (0...1).contains(point.x), (0...1).contains(point.y) else { return nil }
        return point
    }

    public static func assess(_ face: FaceInfo, intent: ShootingIntent = .general,
                              eyesClosedThreshold: Float = 0.16) -> FaceAssessment {
        let threshold = validRatio(eyesClosedThreshold) ?? 0.16
        // Landmark ratios close to a user threshold cannot support a confident blink
        // rejection. Keep a narrow dead band rather than amplifying measurement noise.
        let closedLimit = max(0, threshold - 0.025)
        let yaw = validAngle(face.yaw), pitch = validAngle(face.pitch)
        let headTurned = (yaw.map { abs($0) > 0.3 } ?? false) || (pitch.map { abs($0) > 0.3 } ?? false)
        let frontal = yaw.map { abs($0) <= 0.3 } == true && pitch.map { abs($0) <= 0.3 } == true
        let poseUnreliable = (face.yaw != nil && yaw == nil) || (face.pitch != nil && pitch == nil)
        let left = supported(face.leftEyeOpenness, confidence: face.leftEyeConfidence)
        let right = supported(face.rightEyeOpenness, confidence: face.rightEyeConfidence)
        let hasIndividualEvidence = face.leftEyeOpenness != nil || face.rightEyeOpenness != nil
            || face.leftEyeConfidence != nil || face.rightEyeConfidence != nil

        var eyes: EyeState = .unknown
        if face.isSignificant && !poseUnreliable {
            if let left, let right, frontal {
                if left < closedLimit && right < closedLimit { eyes = .closed }
                else if (left < closedLimit && right >= threshold) || (right < closedLimit && left >= threshold) { eyes = .oneEyeClosed }
                else if left >= threshold && right >= threshold { eyes = .open }
            } else if (left.map { $0 >= threshold } == true && right.map { $0 >= threshold } == true)
                        || (headTurned && (left.map { $0 >= threshold } == true || right.map { $0 >= threshold } == true)) {
                // A supported open visible eye in a profile is not a blink. We make
                // no claim about the occluded eye and still leave gaze unknown.
                eyes = .open
            } else if !hasIndividualEvidence && !headTurned, let aggregate = validRatio(face.eyeOpenness) {
                // Old cached/test data has only the more-open eye. Preserve that contract,
                // without deriving a wink or camera attention from absent evidence.
                eyes = aggregate < threshold ? .closed : .open
            }
        }

        var attention: CameraAttention = .unknown
        if eyes == .open, frontal, let leftPupil = validPupil(face.leftPupilPosition),
           let rightPupil = validPupil(face.rightPupilPosition), left != nil, right != nil {
            let lx = leftPupil.x - 0.5, rx = rightPupil.x - 0.5
            let ly = leftPupil.y - 0.5, ry = rightPupil.y - 0.5
            let consistent = abs(lx - rx) <= 0.12 && abs(ly - ry) <= 0.20
            if consistent && abs(lx) <= 0.13 && abs(rx) <= 0.13 && abs(ly) <= 0.25 && abs(ry) <= 0.25 {
                attention = .towardCamera
            } else if consistent && lx * rx > 0 && abs(lx) >= 0.25 && abs(rx) >= 0.25
                        && abs(ly) <= 0.30 && abs(ry) <= 0.30 {
                attention = .awayFromCamera
            }
        }

        let eyeDescription: String
        switch eyes {
        case .open: eyeDescription = headTurned ? "Visible eye appears open; hidden eye state unknown" : "Eyes appear open"
        case .closed: eyeDescription = "Both eyes appear closed"
        case .oneEyeClosed: eyeDescription = "One eye may be closed / wink"
        case .unknown: eyeDescription = "Eye state unknown"
        }
        let attentionDescription: String
        switch attention {
        case .towardCamera: attentionDescription = "Camera attention likely (pupil estimate)"
        case .awayFromCamera: attentionDescription = "May be looking away (pupil estimate)"
        case .unknown: attentionDescription = "Camera attention unknown"
        }
        let poseDescription = yaw == nil || pitch == nil ? "Head pose unavailable"
            : headTurned ? "Head turned or tilted; this does not establish gaze" : "Head approximately frontal"
        var messages: [String] = []
        if face.isSignificant {
            if eyes == .oneEyeClosed { messages.append("One eye may be closed or winking; inspect before accepting.") }
            if eyes == .unknown { messages.append("Eye state could not be assessed reliably (pose, occlusion or landmark support); inspect this face.") }
            if intent.requiresCameraAttention && eyes != .closed {
                switch attention {
                case .unknown: messages.append("Camera attention is unknown; head pose alone is not gaze. Review this posed face.")
                case .awayFromCamera: messages.append("Pupils suggest possible looking away; review this posed face rather than automatically rejecting it.")
                case .towardCamera: break
                }
            }
        }
        return FaceAssessment(eyeState: eyes, cameraAttention: attention, headTurned: headTurned,
            eyeDescription: eyeDescription, attentionDescription: attentionDescription,
            headPoseDescription: poseDescription,
            eyeConfidenceDescription: eyes == .unknown ? "Insufficient reliable eye evidence" : hasIndividualEvidence ? "Supported landmark estimate; verify at 100%" : "Legacy aggregate eye estimate",
            attentionConfidenceDescription: attention == .unknown ? "Insufficient gaze evidence" : "Limited geometric estimate; not calibrated gaze tracking",
            reviewMessages: messages)
    }

    public static func assessments(for analysis: PhotoAnalysis, options: ScoringOptions = ScoringOptions()) -> [FaceAssessment] {
        analysis.significantFaces.map { assess($0, intent: options.shootingIntent, eyesClosedThreshold: options.eyesClosedThreshold) }
    }

    public static func reviewMessages(for analysis: PhotoAnalysis, options: ScoringOptions = ScoringOptions()) -> [String] {
        var messages: [String] = []
        for (index, face) in analysis.faces.enumerated() {
            if face.isSignificant {
                messages += assess(face, intent: options.shootingIntent, eyesClosedThreshold: options.eyesClosedThreshold)
                    .reviewMessages.map { "Face \(index + 1): \($0)" }
            } else if options.shootingIntent == .groupPortrait {
                let b = face.boundingBox
                if b.width.isFinite && b.height.isFinite && b.minX.isFinite && b.minY.isFinite
                    && b.width >= 0.025 && b.height >= 0.025 && b.minX >= 0 && b.minY >= 0 && b.maxX <= 1.0001 && b.maxY <= 1.0001 {
                    messages.append("Face \(index + 1): Too small to assess eyes or camera attention reliably; review if part of the posed group.")
                }
            }
        }
        if analysis.significantFaces.isEmpty && options.shootingIntent.requiresCameraAttention {
            messages.append("No significant face could be assessed for this posed photo; inspect people before accepting.")
        }
        return messages
    }
}
