import XCTest
@testable import CullCore

final class BurstRecommendationTests: XCTestCase {
    private var options: ScoringOptions {
        var options = ScoringOptions()
        options.shootingIntent = .groupPortrait
        return options
    }

    private func face(_ x: CGFloat, eyes: Float = 0.32, pupil: CGFloat? = 0.5, width: CGFloat = 0.08) -> FaceInfo {
        let point = pupil.map { CGPoint(x: $0, y: 0.5) }
        return FaceInfo(boundingBox: CGRect(x: x, y: 0.38, width: width, height: width * 1.3),
                        leftEyeOpenness: eyes, rightEyeOpenness: eyes, leftEyeConfidence: 0.95,
                        rightEyeConfidence: 0.95, yaw: 0, pitch: 0, roll: 0,
                        leftPupilPosition: point, rightPupilPosition: point)
    }

    private func shot(_ name: String, _ faces: [FaceInfo], focus: Float = 400) -> PhotoItem {
        var item = PhotoItem(url: URL(fileURLWithPath: "/fixture/\(name).jpg"))
        item.analysis = PhotoAnalysis(pixelWidth: 3000, pixelHeight: 2000, captureDate: nil,
                                      sharpness: focus, subjectSharpness: focus, meanLuminance: 0.5,
                                      highlightClipping: 0, shadowClipping: 0, faces: faces)
        return item
    }

    func testTenImperfectShotsShowDecisivePairUsingOriginalIndices() throws {
        let winner = shot("07", [face(0.45), face(0.78, pupil: 0.85), face(0.12)])
        let second = shot("04", [face(0.12), face(0.45, eyes: 0.03), face(0.78)])
        let rest = (0..<8).map { shot("other\($0)", [face(0.45, eyes: 0.02), face(0.12, eyes: 0.02), face(0.78)]) }
        let items = [second] + rest + [winner]
        let result = try XCTUnwrap(BurstRecommender.recommend(items, options: options))
        XCTAssertEqual(result.winnerID, winner.id)
        XCTAssertEqual(result.runnerUpID, second.id)
        XCTAssertFalse(result.isCloseCall)
        XCTAssertEqual(result.pairs.first?.winnerFaceIndex, 0)
        XCTAssertEqual(result.pairs.first?.runnerUpFaceIndex, 1)
        XCTAssertTrue(result.reason.localizedCaseInsensitiveContains("blink"))
        XCTAssertTrue(result.winnerSummary.localizedCaseInsensitiveContains("away"))
        XCTAssertEqual(result, BurstRecommender.recommend(items.reversed(), options: options))
    }

    func testLosingAGroupMemberCannotImproveAShotEvenWhenSharper() throws {
        let full = shot("full", [face(0.15), face(0.65, eyes: 0.03)])
        let missing = shot("missing", [face(0.15)], focus: 900)
        let result = try XCTUnwrap(BurstRecommender.recommend([missing, full], options: options))
        XCTAssertEqual(result.winnerID, full.id)
        XCTAssertEqual(result.pairs.first?.winnerFaceIndex, 1)
        XCTAssertNil(result.pairs.first?.runnerUpFaceIndex)
        XCTAssertTrue(result.reason.localizedCaseInsensitiveContains("detect"))
    }

    func testTransientBackgroundFaceCannotWinOrPenalizeAnOtherwiseTiedFrame() throws {
        let base = [face(0.12), face(0.64)]
        let ordinary = shot("B", base)
        let extra = shot("A", base + [face(0.89, eyes: 0.03)])
        let other = shot("C", base)
        let result = try XCTUnwrap(BurstRecommender.recommend([ordinary, extra, other], options: options))
        XCTAssertEqual(result.winnerID, extra.id)
        XCTAssertEqual(result.runnerUpID, ordinary.id)
        XCTAssertTrue(result.isCloseCall)
        XCTAssertFalse(result.winnerSummary.localizedCaseInsensitiveContains("blink"))
    }

    func testAmbiguousOrDistantFacesNeverInventACorrespondence() throws {
        let first = shot("first", [face(0.13), face(0.40), face(0.43)])
        let second = shot("second", [face(0.13), face(0.414), face(0.75)])
        let result = try XCTUnwrap(BurstRecommender.recommend([first, second], options: options))
        let paired = result.pairs.filter { $0.winnerFaceIndex != nil && $0.runnerUpFaceIndex != nil }
        XCTAssertEqual(paired.count, 1)
        XCTAssertEqual(paired.first?.winnerFaceIndex, 0)
        XCTAssertEqual(Set(result.pairs.compactMap(\.winnerFaceIndex)), [0, 1, 2])
        XCTAssertEqual(Set(result.pairs.compactMap(\.runnerUpFaceIndex)), [0, 1, 2])
    }

    func testInvalidPendingAndNonGroupInputsCannotProducePhantomWinner() throws {
        let good = shot("good", [face(0.2), face(0.6)])
        var pending = good
        pending.analysis = nil
        let broken = shot("broken", [face(0.2), face(0.6)], focus: .nan)
        var errored = shot("error", [face(0.2), face(0.6)])
        errored.analysisError = "Cannot read image"
        XCTAssertNil(BurstRecommender.recommend([pending, good, broken, errored], options: options))
        XCTAssertNil(BurstRecommender.recommend([good, good], options: options))
        XCTAssertNil(BurstRecommender.recommend([good, shot("other", [face(0.1), face(0.6)])], options: ScoringOptions()))
        XCTAssertNil(BurstRecommender.recommend([shot("a", []), shot("b", [])], options: options))
        XCTAssertNil(BurstRecommender.recommend([shot("a", [face(0.2)]), shot("b", [face(0.2)])], options: options))
    }

    func testCloseCallUsesStableOrderingAndNeverClaimsGazeFromHeadPose() throws {
        let faces = [face(0.2, pupil: nil), face(0.6, pupil: nil)]
        let a = shot("A", faces)
        let b = shot("B", faces)
        let result = try XCTUnwrap(BurstRecommender.recommend([b, a], options: options))
        XCTAssertTrue(result.isCloseCall)
        XCTAssertEqual(result.winnerID, a.id)
        XCTAssertTrue(result.winnerSummary.localizedCaseInsensitiveContains("unknown"))
        XCTAssertTrue(result.reason.localizedCaseInsensitiveContains("close"))
        XCTAssertTrue(result.pairs.allSatisfy { !$0.label.isEmpty })
    }

    func testPoorTechnicalQualityAndSmallFocusDifferencesAreDistinguished() throws {
        let faces = [face(0.2), face(0.6)]
        let sharp = shot("sharp", faces, focus: 400)
        let soft = shot("soft", faces, focus: 12)
        let almost = shot("almost", faces, focus: 390)
        let strong = try XCTUnwrap(BurstRecommender.recommend([soft, sharp], options: options))
        XCTAssertEqual(strong.winnerID, sharp.id)
        XCTAssertTrue(strong.reason.localizedCaseInsensitiveContains("focus"))
        XCTAssertFalse(strong.isCloseCall)
        let close = try XCTUnwrap(BurstRecommender.recommend([almost, sharp], options: options))
        XCTAssertTrue(close.isCloseCall)
    }

    func testDecisiveFocusDifferenceShowsTheRunnerUpsSoftFaceFirst() throws {
        var steady = face(0.12)
        steady.sharpness = 450
        var wellFocused = face(0.70)
        wellFocused.sharpness = 410
        var soft = face(0.70)
        soft.sharpness = 90
        let winner = shot("A", [steady, wellFocused], focus: 410)
        let runner = shot("B", [soft, steady], focus: 90)
        let result = try XCTUnwrap(BurstRecommender.recommend([winner, runner], options: options))
        XCTAssertEqual(result.pairs.first?.winnerFaceIndex, 1)
        XCTAssertEqual(result.pairs.first?.runnerUpFaceIndex, 0)
    }

    func testMissingDetectionWithBackgroundReplacementDoesNotGainRank() throws {
        let blink = [face(0.1), face(0.52, eyes: 0.03)]
        let a = shot("B", blink), b = shot("C", blink)
        let substituted = shot("A", [face(0.1), face(0.86)], focus: 1000)
        let result = try XCTUnwrap(BurstRecommender.recommend([substituted, a, b, shot("D", blink)], options: options))
        XCTAssertEqual(result.winnerID, a.id)
        XCTAssertEqual(result.runnerUpID, b.id)
    }

    func testFrameWithoutAnyValidFaceCannotBeRunnerUp() {
        let only = shot("A", [face(0.15), face(0.6)])
        let empty = shot("B", [])
        XCTAssertNil(BurstRecommender.recommend([only, empty], options: options))
    }

    func testIncompatibleSurroundingColorVetoesEvenIdenticalFacePositions() throws {
        var red = face(0.15), blue = face(0.15)
        red.surroundingColor = BurstFaceContext(red: 220, green: 25, blue: 25)
        blue.surroundingColor = BurstFaceContext(red: 15, green: 30, blue: 210)
        let first = shot("A", [red, face(0.7)])
        let second = shot("B", [face(0.7), blue])
        let result = try XCTUnwrap(BurstRecommender.recommend([first, second], options: options))
        XCTAssertFalse(result.pairs.contains { $0.winnerFaceIndex == 0 && $0.runnerUpFaceIndex == 1 })
        XCTAssertTrue(result.pairs.contains { $0.winnerFaceIndex == 0 && $0.runnerUpFaceIndex == nil })
        XCTAssertTrue(result.pairs.contains { $0.winnerFaceIndex == nil && $0.runnerUpFaceIndex == 1 })
    }

    func testTiedBlinkTradeOffShowsBothChangedPositionsBeforeUnchangedFaces() throws {
        let a = shot("A", [face(0.1), face(0.22, eyes: 0.03), face(0.7)])
        let b = shot("B", [face(0.1), face(0.22), face(0.7, eyes: 0.03)])
        let result = try XCTUnwrap(BurstRecommender.recommend([a, b], options: options))
        XCTAssertTrue(result.isCloseCall)
        XCTAssertTrue(result.reason.localizedCaseInsensitiveContains("different positions"))
        XCTAssertEqual(Set(result.pairs.prefix(2).compactMap(\.winnerFaceIndex)), [1, 2])
        XCTAssertEqual(Set(result.pairs.map(\.label)).count, result.pairs.count)
    }

    func testSoftTransientBackgroundFaceDoesNotSetGroupFocus() throws {
        var left = face(0.1), right = face(0.6), background = face(0.88)
        left.sharpness = 450
        right.sharpness = 390
        background.sharpness = 20
        let a = shot("A", [left, right, background], focus: 20)
        let b = shot("B", [left, right], focus: 390), c = shot("C", [left, right], focus: 390)
        let result = try XCTUnwrap(BurstRecommender.recommend([c, b, a], options: options))
        XCTAssertEqual(result.winnerID, a.id)
        XCTAssertTrue(result.isCloseCall)
        XCTAssertFalse(result.winnerSummary.localizedCaseInsensitiveContains("soft"))

        var chosen = a
        chosen.analysis?.subjectSharpness = 450
        let keySubject = try XCTUnwrap(BurstRecommender.recommend([c, b, chosen], options: options))
        XCTAssertTrue(keySubject.reason.localizedCaseInsensitiveContains("differs only slightly"))
    }

    func testFailedFaceMeasurementCannotWinButUnrelatedWarningsKeepEvidence() throws {
        let faces = [face(0.15), face(0.65)]
        var failed = shot("A", faces, focus: 900)
        failed.analysis?.analysisWarnings = ["Face analysis unavailable: test detector failure"]
        var unavailableLabels = shot("B", faces, focus: 600)
        unavailableLabels.analysis?.analysisWarnings = ["Search labels unavailable: test classification failure"]
        let usable = shot("C", faces)
        let result = try XCTUnwrap(BurstRecommender.recommend([failed, usable, unavailableLabels], options: options))
        XCTAssertEqual(result.winnerID, unavailableLabels.id)
        XCTAssertEqual(result.runnerUpID, usable.id)
    }
}
