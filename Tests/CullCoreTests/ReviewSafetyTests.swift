import Foundation
import XCTest
@testable import CullCore

final class ReviewSafetyTests: XCTestCase {
    private func photo(_ name: String, sharpness: Float, warnings: [String] = []) -> PhotoItem {
        var photo = PhotoItem(url: URL(fileURLWithPath: "/tmp/\(name).jpg"))
        photo.analysis = PhotoAnalysis(pixelWidth: 100, pixelHeight: 100,
            captureDate: Date(timeIntervalSince1970: 0), sharpness: sharpness, subjectSharpness: sharpness,
            meanLuminance: 0.5, highlightClipping: 0, shadowClipping: 0, faces: [],
            aestheticScore: sharpness > 1000 ? 1 : 0.3, featurePrint: Embedding.normalized([1, 0]),
            analysisWarnings: warnings)
        return photo
    }

    func testUncertainMeasurementCannotCondemnReliableFrameOrBecomeBest() {
        var items = [photo("reliable", sharpness: 300),
                     photo("uncertain", sharpness: 3000, warnings: ["High noise: review focus"])]
        Scorer.evaluate(&items)
        XCTAssertFalse(items[0].issues.contains(.blurry))
        XCTAssertEqual(items[0].suggestion, .pick)
        XCTAssertTrue(items[0].isBestInGroup)
        XCTAssertEqual(items[1].suggestion, .undecided)
        XCTAssertFalse(items[1].isBestInGroup)
    }

    func testGroupContainingOnlyUncertainAnalysesHasNoBest() {
        var items = [photo("a", sharpness: 300, warnings: ["Partial analysis"]),
                     photo("b", sharpness: 3000, warnings: ["High noise"])]
        Scorer.evaluate(&items)
        XCTAssertTrue(items.allSatisfy { !$0.isBestInGroup && $0.suggestion == .undecided && $0.needsReview })
    }

    func testTargetDoesNotTurnAmbiguousAlternativesIntoActionablePicks() {
        var items = [photo("a", sharpness: 500), photo("b", sharpness: 500)]
        Scorer.evaluate(&items)
        XCTAssertEqual(items.filter(\.needsReview).count, 1)
        let proposed = Scorer.cullToTarget(&items, count: 2)
        let actionablePicks = items.filter { $0.suggestion == .pick && !$0.needsReview }.count
        XCTAssertEqual(proposed, actionablePicks)
        XCTAssertEqual(proposed, 1)
        XCTAssertTrue(items.filter(\.needsReview).allSatisfy { $0.suggestion == .undecided })
    }
}
