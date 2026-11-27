import Foundation
import XCTest
@testable import CullCore

final class PreferenceTests: XCTestCase {
    private func facts(sharpness: Float, aesthetic: Float) -> PhotoAnalysis {
        .init(pixelWidth: 100, pixelHeight: 100, captureDate: nil, sharpness: sharpness, subjectSharpness: sharpness,
              meanLuminance: 0.5, highlightClipping: 0, shadowClipping: 0, faces: [], aestheticScore: aesthetic)
    }
    func testProfileIsNeutralUntilItHasBalancedEvidence() {
        var p = PreferenceProfile()
        for i in 0..<20 { p.record(analysis: facts(sharpness: 100, aesthetic: 0.7), decision: .pick, sampleID: String(i)) }
        XCTAssertFalse(p.isReady)
        XCTAssertEqual(p.adjustment(for: facts(sharpness: 100, aesthetic: 0.7)), 0)
    }
    func testExplicitExamplesLearnHeldOutPreferenceAndRoundTrip() throws {
        var p = PreferenceProfile()
        // The labels prefer aesthetic quality over raw sharpness. Evaluation points are held out.
        for i in 0..<12 {
            p.record(analysis: facts(sharpness: 200 + Float(i), aesthetic: 0.55 + Float(i)/100), decision: .pick, sampleID: "p\(i)")
            p.record(analysis: facts(sharpness: 800 + Float(i), aesthetic: -0.55 - Float(i)/100), decision: .reject, sampleID: "r\(i)")
        }
        XCTAssertTrue(p.isReady)
        let accepted = facts(sharpness: 250, aesthetic: 0.75), rejected = facts(sharpness: 850, aesthetic: -0.75)
        XCTAssertGreaterThan(p.adjustment(for: accepted), 0)
        XCTAssertLessThan(p.adjustment(for: rejected), 0)
        let decoded = try JSONDecoder().decode(PreferenceProfile.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(decoded.adjustment(for: accepted), p.adjustment(for: accepted), accuracy: 0.001)
    }
    func testChangingSamePhotoReplacesExampleInsteadOfInflatingTraining() {
        var p = PreferenceProfile()
        let a = facts(sharpness: 100, aesthetic: 0)
        for _ in 0..<50 { p.record(analysis: a, decision: .pick, sampleID: "same-photo") }
        XCTAssertEqual(p.sampleCount, 1)
        p.record(analysis: a, decision: .undecided, sampleID: "same-photo")
        XCTAssertEqual(p.sampleCount, 0)
    }
    func testExactDuplicateSearchFindsNonAdjacentNames() throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("OpenCull-Duplicates-\(UUID())")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: d) }
        for (name,data) in [("a.jpg",Data([1,2,3])),("b.jpg",Data([7,8,9])),("z.jpg",Data([1,2,3]))] {
            try data.write(to: d.appendingPathComponent(name))
        }
        let groups = try ExactDuplicateFinder.groups(in: PhotoScanner.scan(folder: d))
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].map { URL(fileURLWithPath: $0).lastPathComponent }, ["a.jpg", "z.jpg"])
    }
    func testTargetCullPreservesChoicesAndDoesNotForceUnsafePicks() {
        var items = (0..<4).map { PhotoItem(url: URL(fileURLWithPath: "/tmp/\($0).jpg")) }
        for i in items.indices { items[i].analysis = facts(sharpness: Float(200+i*50), aesthetic: 0.2) }
        items[0].decision = .pick; items[1].decision = .reject
        items[3].analysis?.analysisWarnings = ["Focus requires review"]
        Scorer.evaluate(&items)
        let proposed = Scorer.cullToTarget(&items, count: 3)
        XCTAssertEqual(items[0].decision, .pick); XCTAssertEqual(items[1].decision, .reject)
        XCTAssertNotEqual(items[3].suggestion, .pick)
        XCTAssertEqual(proposed, 2)
    }

    func testManualGroupSplitAndMergeUseTheSameConservativeScoring() {
        var items = (0..<3).map { PhotoItem(url: URL(fileURLWithPath: "/tmp/group-\($0).jpg")) }
        for i in items.indices {
            items[i].analysis = facts(sharpness: 500, aesthetic: 0.2)
            items[i].analysis?.featurePrint = Embedding.normalized([1,0])
        }
        Scorer.evaluate(&items, groupOverrides: [items[0].id: "separate"])
        XCTAssertEqual(items[0].groupSize, 1)
        XCTAssertEqual(items[1].groupSize, 2)
        XCTAssertNotEqual(items[0].groupID, items[1].groupID)
        items[1].analysis?.analysisWarnings = ["Check subject focus"]
        Scorer.evaluate(&items, groupOverrides: Dictionary(uniqueKeysWithValues: items.map { ($0.id,"merged") }))
        XCTAssertEqual(Set(items.compactMap(\.groupID)).count, 1)
        XCTAssertTrue(items.allSatisfy { $0.groupSize == 3 })
        XCTAssertEqual(items[1].suggestion, .undecided)
        XCTAssertTrue(items[1].needsReview)
    }
    func testMalformedPreferenceFeaturesAreRejected() {
        let data = Data("{\"samples\":[{\"id\":\"bad\",\"features\":[1],\"picked\":true}]}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(PreferenceProfile.self, from: data))
    }
    func testHighlyRatedPicksCarryMorePreferenceEvidence() {
        var neutral = PreferenceProfile(), rated = PreferenceProfile()
        for i in 0..<12 {
            let positive = facts(sharpness: 300, aesthetic: i < 6 ? 0.8 : -0.2)
            neutral.record(analysis: positive, decision: .pick, rating: 0, sampleID: "p\(i)")
            rated.record(analysis: positive, decision: .pick, rating: i < 6 ? 5 : 0, sampleID: "p\(i)")
            let negative = facts(sharpness: 200, aesthetic: -0.8)
            neutral.record(analysis: negative, decision: .reject, sampleID: "r\(i)")
            rated.record(analysis: negative, decision: .reject, sampleID: "r\(i)")
        }
        let candidate = facts(sharpness: 300, aesthetic: 0.8)
        XCTAssertNotEqual(rated.adjustment(for: candidate), neutral.adjustment(for: candidate))
    }
}
