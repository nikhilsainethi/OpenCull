import CullCore
import Foundation
import XCTest
@testable import OpenCull

/// Review regressions use a completely isolated workspace and UserDefaults suite.
final class IntegrationReviewerTests: XCTestCase {
    @MainActor private func workspace(count: Int = 5) async throws -> LibraryModel {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("OpenCull-Reviewer-\(UUID().uuidString)")
        let photos = root.appendingPathComponent("Photos"), data = root.appendingPathComponent("Data")
        try fm.createDirectory(at: photos, withIntermediateDirectories: true)
        for i in 0..<count { try Data([UInt8(i)]).write(to: photos.appendingPathComponent(String(format: "%02d", i) + ".jpg")) }
        let store = SessionStore(folder: photos, baseDirectory: data.appendingPathComponent("Sessions"))
        let scanned = try PhotoScanner.scan(folder: photos)
        var cache: [String: PhotoAnalysis] = [:]
        for (i, item) in scanned.enumerated() {
            cache[store.analysisKey(for: item)] = PhotoAnalysis(pixelWidth: 100, pixelHeight: 100,
                captureDate: Date(timeIntervalSince1970: Double(i * 30)), sharpness: 300, subjectSharpness: 300,
                meanLuminance: 0.5, highlightClipping: 0, shadowClipping: 0, faces: [], labels: [i == 2 ? "hidden" : "visible"])
        }
        try store.saveAnalysis(cache)
        let suite = "OpenCull-Reviewer-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = LibraryModel(appDataDirectory: data, defaults: defaults)
        model.autoAdvance = false
        await model.open(photos)
        XCTAssertFalse(model.isAnalyzing)
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suite)
            try? fm.removeItem(at: root)
        }
        return model
    }

    @MainActor func testFilteringKeepsActivePhotoInsideSurvivingBatchSelection() async throws {
        let model = try await workspace(count: 3)
        let first = model.items[0].id, survivor = model.items[1].id, hidden = model.items[2].id
        model.select(survivor)
        model.select(hidden, extending: true)
        XCTAssertEqual(model.selectedID, hidden)
        model.searchText = "visible"
        XCTAssertEqual(model.selection, [survivor])
        XCTAssertEqual(model.selectedID, survivor, "The active photo must come from the surviving selection before an unrelated first visible photo")
        XCTAssertTrue(model.selection.contains(try XCTUnwrap(model.selectedID)))
        model.setRating(5)
        XCTAssertEqual(model.items.first { $0.id == survivor }?.rating, 5)
        XCTAssertEqual(model.items.first { $0.id == first }?.rating, 0)
        XCTAssertTrue(model.flushPendingSaves())
    }

    @MainActor func testComparisonTruncationKeepsActivePhotoInsideComparisonSelection() async throws {
        let model = try await workspace()
        model.selectAllVisible()
        model.select(model.items[4].id, extending: true) // toggles off; put it back as the active member
        model.select(model.items[4].id, extending: true)
        XCTAssertEqual(model.selection.count, 5)
        model.prepareComparison()
        XCTAssertEqual(model.comparisonItems.count, 4)
        XCTAssertTrue(model.selection.contains(try XCTUnwrap(model.selectedID)))
        XCTAssertTrue(model.comparisonItems.contains { $0.id == model.selectedID })
        XCTAssertTrue(model.flushPendingSaves())
    }

    @MainActor func testSelectAllInComparisonNeverRatesPhotosOutsideVisibleComparison() async throws {
        let model = try await workspace()
        model.mode = .compare
        model.selectAllVisible()
        let displayed = Set(model.comparisonItems.map(\.id))
        XCTAssertEqual(model.selection, displayed)
        model.setRating(5)
        XCTAssertTrue(model.items.filter { !displayed.contains($0.id) }.allSatisfy { $0.rating == 0 })
        XCTAssertTrue(model.flushPendingSaves())
    }
}
