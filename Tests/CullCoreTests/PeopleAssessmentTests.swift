import CoreGraphics
import Foundation
import XCTest
@testable import CullCore

final class PeopleAssessmentTests: XCTestCase {
    private let box = CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.4)

    private func analysis(_ faces: [FaceInfo], sharpness: Float = 500) -> PhotoAnalysis {
        PhotoAnalysis(pixelWidth: 1600, pixelHeight: 1200,
            captureDate: Date(timeIntervalSince1970: 0), sharpness: sharpness,
            subjectSharpness: sharpness, meanLuminance: 0.5, highlightClipping: 0,
            shadowClipping: 0, faces: faces, featurePrint: Embedding.normalized([1, 0]))
    }

    private func face(left: Float? = 0.3, right: Float? = 0.3,
                      leftConfidence: Float? = 0.95, rightConfidence: Float? = 0.95,
                      yaw: Float? = 0, pitch: Float? = 0,
                      pupil: CGPoint? = CGPoint(x: 0.5, y: 0.5)) -> FaceInfo {
        FaceInfo(boundingBox: box, eyeOpenness: max(left ?? 0, right ?? 0), sharpness: 500,
                 leftEyeOpenness: left, rightEyeOpenness: right,
                 leftEyeConfidence: leftConfidence, rightEyeConfidence: rightConfidence,
                 yaw: yaw, pitch: pitch, roll: 0,
                 leftPupilPosition: pupil, rightPupilPosition: pupil)
    }

    private func item(_ name: String, faces: [FaceInfo], sharpness: Float = 500) -> PhotoItem {
        var item = PhotoItem(url: URL(fileURLWithPath: "/tmp/\(name).jpg"))
        item.analysis = analysis(faces, sharpness: sharpness)
        return item
    }

    func testInvalidAggregateEyeMeasurementCannotBecomeClosedEyeRejection() {
        for invalid: Float in [-0.1, .nan, .infinity, -.infinity, 2] {
            let a = analysis([FaceInfo(boundingBox: box, eyeOpenness: invalid)])
            XCTAssertFalse(Scorer.hasClosedEyes(a, options: ScoringOptions()), "Invalid eye ratio \(invalid)")
        }
    }

    func testOldFaceAndScoringJSONDecodeWithUnknownNewEvidenceAndGeneralIntent() throws {
        let old = FaceInfo(boundingBox: box, captureQuality: 0.6, eyeOpenness: 0.3, sharpness: 500)
        let encoded = try JSONEncoder().encode(old)
        let decoded = try JSONDecoder().decode(FaceInfo.self, from: encoded)
        XCTAssertNil(decoded.leftEyeOpenness)
        XCTAssertNil(decoded.rightEyeConfidence)
        XCTAssertNil(decoded.yaw)
        XCTAssertNil(decoded.leftPupilPosition)
        XCTAssertEqual(PeopleAssessment.assess(decoded).eyeState, .open)
        XCTAssertEqual(PeopleAssessment.assess(decoded).cameraAttention, .unknown)
        XCTAssertEqual(try JSONDecoder().decode(ScoringOptions.self, from: Data("{}".utf8)).shootingIntent, .general)
        XCTAssertEqual(Set(ShootingIntent.allCases.map(\.rawValue)).count, 5)
        for intent in ShootingIntent.allCases {
            XCTAssertFalse(intent.title.isEmpty)
            XCTAssertFalse(intent.help.isEmpty)
        }
        XCTAssertGreaterThan(PhotoAnalysis.currentVersion, 3)
    }

    func testHeadPoseWithoutPupilEvidenceNeverClaimsEyeGaze() {
        for yaw: Float in [0, 0.2, 0.8] {
            let assessed = PeopleAssessment.assess(face(yaw: yaw, pupil: nil), intent: .posedPortrait)
            XCTAssertEqual(assessed.cameraAttention, .unknown)
            XCTAssertFalse(assessed.reviewMessages.isEmpty)
        }
        XCTAssertTrue(PeopleAssessment.assess(face(yaw: 0.8)).headTurned)
    }

    func testReliableFrontalEyesDistinguishOpenClosedAndWink() {
        XCTAssertEqual(PeopleAssessment.assess(face()).eyeState, .open)
        XCTAssertEqual(PeopleAssessment.assess(face(left: 0.03, right: 0.04)).eyeState, .closed)
        let wink = PeopleAssessment.assess(face(left: 0.03, right: 0.3))
        XCTAssertEqual(wink.eyeState, .oneEyeClosed)
        XCTAssertFalse(wink.reviewMessages.isEmpty)
        XCTAssertFalse(Scorer.hasClosedEyes(analysis([face(left: 0.03, right: 0.3)]), options: ScoringOptions()))
        XCTAssertTrue(Scorer.hasClosedEyes(analysis([face(left: 0.03, right: 0.04)]), options: ScoringOptions()))
    }

    func testEyesNearClosureThresholdRequireReviewInsteadOfConfidentRejection() {
        let borderline = face(left: 0.15, right: 0.15)
        XCTAssertEqual(PeopleAssessment.assess(borderline).eyeState, .unknown)
        var items = [item("borderline", faces: [borderline])]
        Scorer.evaluate(&items)
        XCTAssertEqual(items[0].suggestion, .undecided)
        XCTAssertTrue(items[0].needsReview)
        XCTAssertFalse(items[0].issues.contains(.eyesClosed))
    }

    func testProfileHiddenEyeAndLowConfidenceStayUnknown() {
        let uncertain = [face(left: 0.03, right: 0.03, yaw: 0.9),
                         face(left: nil, right: 0.03, yaw: 0.9),
                         face(left: 0.03, right: 0.03, leftConfidence: 0.2),
                         face(left: 0.03, right: 0.03, leftConfidence: .nan),
                         face(left: 0.03, right: 0.03, yaw: .infinity)]
        for value in uncertain {
            let result = PeopleAssessment.assess(value, intent: .groupPortrait)
            XCTAssertEqual(result.eyeState, .unknown)
            XCTAssertEqual(result.cameraAttention, .unknown)
            XCTAssertFalse(result.reviewMessages.isEmpty)
            XCTAssertFalse(Scorer.hasClosedEyes(analysis([value]), options: ScoringOptions()))
        }
    }

    func testCameraAttentionRequiresSupportedConsistentPupils() {
        XCTAssertEqual(PeopleAssessment.assess(face()).cameraAttention, .towardCamera)
        XCTAssertEqual(PeopleAssessment.assess(face(pupil: CGPoint(x: 0.85, y: 0.5))).cameraAttention, .awayFromCamera)
        var mismatch = face(); mismatch.leftPupilPosition = CGPoint(x: 0.85, y: 0.5)
        XCTAssertEqual(PeopleAssessment.assess(mismatch).cameraAttention, .unknown)
        for point in [CGPoint(x: .nan, y: 0.5), CGPoint(x: 2, y: 0.5)] {
            XCTAssertEqual(PeopleAssessment.assess(face(pupil: point)).cameraAttention, .unknown)
        }
        var small = face(); small.boundingBox.size.width = 0.03
        XCTAssertEqual(PeopleAssessment.assess(small).eyeState, .unknown)
        XCTAssertEqual(PeopleAssessment.assess(small).cameraAttention, .unknown)
        var invalid = face(); invalid.boundingBox.size.width = .infinity
        XCTAssertFalse(invalid.isSignificant)
    }

    func testLookingAwayIsNeutralForGeneralCandidAndCreativeButReviewedForPosed() {
        for intent in ShootingIntent.allCases {
            var options = ScoringOptions(); options.shootingIntent = intent
            var items = [item("away", faces: [face(pupil: CGPoint(x: 0.85, y: 0.5))])]
            Scorer.evaluate(&items, scoring: options)
            let formal = intent == .posedPortrait || intent == .groupPortrait
            XCTAssertEqual(items[0].suggestion, formal ? .undecided : .pick, intent.rawValue)
            XCTAssertEqual(items[0].needsReview, formal, intent.rawValue)
            XCTAssertFalse(items[0].issues.contains(.eyesClosed))
        }
    }

    func testSupportedOpenProfileIsNeutralForCandidWhileHiddenEyeRemainsUnmeasured() {
        let profile = face(left: nil, right: 0.3, yaw: 0.9)
        let result = PeopleAssessment.assess(profile, intent: .candid)
        XCTAssertEqual(result.eyeState, .open)
        XCTAssertEqual(result.cameraAttention, .unknown)
        XCTAssertTrue(result.eyeDescription.contains("Visible"))
        XCTAssertTrue(result.reviewMessages.isEmpty)
        var options = ScoringOptions(); options.shootingIntent = .candid
        var items = [item("candid-profile", faces: [profile])]
        Scorer.evaluate(&items, scoring: options)
        XCTAssertEqual(items[0].suggestion, .pick)
        XCTAssertFalse(items[0].needsReview)
    }

    func testCreativeBlurRequiresReviewAndCannotBeBestOrReference() {
        var options = ScoringOptions(); options.shootingIntent = .creative
        var items = [item("soft", faces: [], sharpness: 20), item("sharp", faces: [], sharpness: 500)]
        Scorer.evaluate(&items, scoring: options)
        XCTAssertTrue(items[0].issues.contains(.blurry))
        XCTAssertEqual(items[0].suggestion, .undecided)
        XCTAssertTrue(items[0].needsReview)
        XCTAssertFalse(items[0].isBestInGroup)
        XCTAssertEqual(items[1].suggestion, .pick)
        XCTAssertTrue(items[1].isBestInGroup)
        Scorer.cullToTarget(&items, count: 2)
        XCTAssertEqual(items[0].suggestion, .undecided)
    }

    func testEverySignificantFaceIsAssessedAndAllClosedGroupHasNoBest() {
        var second = face(left: 0.03, right: 0.04); second.boundingBox.origin.x = 0.6
        let faces = [face(left: 0.03, right: 0.04), second]
        let assessments = PeopleAssessment.assessments(for: analysis(faces), options: ScoringOptions())
        XCTAssertEqual(assessments.count, 2)
        XCTAssertTrue(assessments.allSatisfy { $0.eyeState == .closed && !$0.summary.isEmpty })
        var items = [item("closed1", faces: faces), item("closed2", faces: faces, sharpness: 1000)]
        Scorer.evaluate(&items)
        XCTAssertTrue(items.allSatisfy { $0.suggestion == .reject && !$0.isBestInGroup })
    }

    func testOneUncertainFacePreventsBestReferenceAndTargetPromotion() {
        let reliable = item("reliable", faces: [face()], sharpness: 300)
        let uncertain = item("uncertain", faces: [face(), face(left: nil)], sharpness: 3000)
        var items = [reliable, uncertain]
        Scorer.evaluate(&items)
        XCTAssertFalse(items[0].issues.contains(.blurry))
        XCTAssertEqual(items[0].suggestion, .pick)
        XCTAssertTrue(items[0].isBestInGroup)
        XCTAssertEqual(items[1].suggestion, .undecided)
        XCTAssertFalse(items[1].isBestInGroup)
        XCTAssertTrue(items[1].reviewReasons.contains { $0.contains("Face 2") })
        XCTAssertEqual(Scorer.cullToTarget(&items, count: 2), 1)
        XCTAssertEqual(items[1].suggestion, .undecided)
    }

    func testSharpFaceDoesNotInheritBackgroundBlur() {
        var a = analysis([face()]); a.sharpness = 5
        XCTAssertFalse(Scorer.issues(for: a, groupMaxSharpness: nil, options: ScoringOptions()).contains(.blurry))
    }

    func testNonfiniteTechnicalMeasurementRequiresReviewAndFiniteScore() {
        for value: Float in [.nan, .infinity, -.infinity, -1] {
            var invalid = item("invalid", faces: [], sharpness: value)
            invalid.analysis?.highlightClipping = .nan
            var items = [invalid]
            Scorer.evaluate(&items)
            XCTAssertEqual(items[0].suggestion, .undecided)
            XCTAssertTrue(items[0].needsReview)
            XCTAssertTrue(items[0].score?.isFinite == true)
        }
    }

    func testPupilPositionUsesEyeAxisAndRejectsInvalidOrMissingGeometry() throws {
        let points = [CGPoint(x: 0, y: 5), CGPoint(x: 5, y: 3), CGPoint(x: 10, y: 5), CGPoint(x: 5, y: 7)]
        let center = try XCTUnwrap(PhotoAnalyzer.pupilPosition(eyePoints: points, pupilPoints: [CGPoint(x: 5, y: 5)]))
        XCTAssertEqual(center.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(center.y, 0.5, accuracy: 0.001)
        let rotated = points.map { CGPoint(x: -$0.y, y: $0.x) }
        let tilted = try XCTUnwrap(PhotoAnalyzer.pupilPosition(eyePoints: rotated, pupilPoints: [CGPoint(x: -5, y: 5)]))
        XCTAssertEqual(tilted.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(tilted.y, 0.5, accuracy: 0.001)
        XCTAssertNil(PhotoAnalyzer.pupilPosition(eyePoints: points, pupilPoints: []))
        XCTAssertNil(PhotoAnalyzer.pupilPosition(eyePoints: points, pupilPoints: [CGPoint(x: 20, y: 5)]))
        XCTAssertNil(PhotoAnalyzer.eyeOpenness(points: points + [CGPoint(x: CGFloat.infinity, y: 0)]))
    }

    func testEyeConfidenceRequiresResolvedEyePixelsAndActualLandmarkSupport() {
        let eye = [CGPoint(x: 0, y: 5), CGPoint(x: 10, y: 3), CGPoint(x: 20, y: 5), CGPoint(x: 10, y: 7)]
        XCTAssertGreaterThanOrEqual(PhotoAnalyzer.eyeLandmarkConfidence(points: eye, landmarkConfidence: 0.9, faceConfidence: 0.95) ?? 0, PeopleAssessment.minimumEyeConfidence)
        let tiny = eye.map { CGPoint(x: $0.x / 4, y: $0.y / 4) }
        XCTAssertLessThan(PhotoAnalyzer.eyeLandmarkConfidence(points: tiny, landmarkConfidence: 0.9, faceConfidence: 0.95) ?? 0, PeopleAssessment.minimumEyeConfidence)
        XCTAssertNil(PhotoAnalyzer.eyeLandmarkConfidence(points: eye, landmarkConfidence: .nan, faceConfidence: 0.9))
        XCTAssertLessThan(PhotoAnalyzer.eyeLandmarkConfidence(points: eye, landmarkConfidence: 0.2, faceConfidence: 0.9) ?? 0, PeopleAssessment.minimumEyeConfidence)
    }

    func testReviewFaceNumbersMatchOriginalFacesAndSmallGroupMembersRemainVisible() {
        var small = face(); small.boundingBox = CGRect(x: 0.1, y: 0.1, width: 0.03, height: 0.04)
        let a = analysis([small, face(left: nil)])
        XCTAssertTrue(PeopleAssessment.reviewMessages(for: a).allSatisfy { $0.hasPrefix("Face 2:") })
        var options = ScoringOptions(); options.shootingIntent = .groupPortrait
        let messages = PeopleAssessment.reviewMessages(for: a, options: options)
        XCTAssertTrue(messages.contains { $0.hasPrefix("Face 1:") && $0.contains("small") })
        XCTAssertTrue(messages.contains { $0.hasPrefix("Face 2:") })
    }

    func testFaceInitializerKeepsMoreOpenAggregateFallbackForNewEyeFields() {
        let face = FaceInfo(boundingBox: box, leftEyeOpenness: 0.03, rightEyeOpenness: 0.3)
        XCTAssertEqual(face.eyeOpenness, 0.3)
    }
}
