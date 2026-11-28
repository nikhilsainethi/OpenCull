import CullCore
import XCTest
@testable import OpenCull

final class BurstWorkspaceTests: XCTestCase {
    /// A cached ten-frame shoot. Everyone is visible, but every frame has a blink.
    @MainActor private func openBurst() async throws -> (LibraryModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenCull-BurstTests-\(UUID())")
        let album = root.appendingPathComponent("Group"), state = root.appendingPathComponent("State")
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for number in 1...10 {
            try Data([UInt8(number)]).write(to: album.appendingPathComponent(String(format: "shot-%02d.jpg", number)))
        }
        let store = SessionStore(folder: album, baseDirectory: state.appendingPathComponent("Sessions"))
        var cache: [String: PhotoAnalysis] = [:]
        for (index, photo) in try PhotoScanner.scan(folder: album).enumerated() {
            let positions: [CGFloat] = [0.15, 0.43, 0.72]
            let faces = positions.enumerated().map { person, x in
                let ratio: Float = person == index % positions.count ? 0.04 : 0.33
                return FaceInfo(boundingBox: CGRect(x: x, y: 0.25, width: 0.13, height: 0.20),
                                sharpness: 180, leftEyeOpenness: ratio, rightEyeOpenness: ratio,
                                leftEyeConfidence: 1, rightEyeConfidence: 1, yaw: 0, pitch: 0,
                                leftPupilPosition: CGPoint(x: 0.5, y: 0.5), rightPupilPosition: CGPoint(x: 0.5, y: 0.5),
                                surroundingColor: BurstFaceContext(red: 120, green: 160, blue: 40))
            }
            cache[store.analysisKey(for: photo)] = PhotoAnalysis(pixelWidth: 1000, pixelHeight: 700,
                captureDate: Date(timeIntervalSince1970: Double(index)), sharpness: 180, subjectSharpness: 180,
                meanLuminance: 0.5, highlightClipping: 0, shadowClipping: 0, faces: faces, featurePrint: Embedding([1, 0]))
        }
        try store.saveAnalysis(cache)
        let model = LibraryModel(appDataDirectory: state, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        await model.open(album)
        model.scoring.shootingIntent = .groupPortrait
        return (model, root)
    }

    @MainActor func testFilteredReviewCanPickEitherFrameAndUndoWithoutChangingOtherShots() async throws {
        let (model, _) = try await openBurst()
        let anchor = try XCTUnwrap(model.items.first)
        let top = try XCTUnwrap(model.burstRecommendation(for: anchor.id))
        let winner = try XCTUnwrap(model.item(withID: top.winnerID))
        let runner = try XCTUnwrap(model.item(withID: top.runnerUpID))
        model.searchText = winner.fileName
        XCTAssertEqual(model.visibleItems.map(\.id), [winner.id])
        XCTAssertEqual(model.burstRecommendation(for: winner.id)?.runnerUpID, runner.id)
        model.pickBurstPhoto(runner.id, from: winner.id)
        XCTAssertEqual(model.item(withID: runner.id)?.decision, .pick)
        XCTAssertEqual(model.counts.picks, 1)
        XCTAssertEqual(model.selectedID, winner.id)
        model.undo()
        XCTAssertEqual(model.counts.undecided, 10)
        let other = try XCTUnwrap(model.items.first { $0.id != runner.id && $0.id != winner.id })
        model.pickBurstPhoto(other.id, from: winner.id)
        XCTAssertEqual(model.counts.undecided, 10)
    }

    @MainActor func testCloseCandidatesSurviveBulkActionsAndFollowIntentAndGroups() async throws {
        let (model, _) = try await openBurst()
        let ids = model.items.map(\.id)
        let top = try XCTUnwrap(model.burstRecommendation(for: ids[0]))
        XCTAssertTrue(top.isCloseCall)
        XCTAssertEqual(model.burstShotNumber(for: ids[9]), 10)
        model.targetCount = 1
        model.suggestTargetCount()
        model.acceptSuggestions()
        for id in [top.winnerID, top.runnerUpID] {
            XCTAssertEqual(model.item(withID: id)?.decision, .undecided)
            XCTAssertTrue(model.item(withID: id)?.needsReview == true)
        }
        model.scoring.shootingIntent = .candid
        XCTAssertNil(model.burstRecommendation(for: ids[0]))
        model.scoring.shootingIntent = .groupPortrait
        XCTAssertNotNil(model.burstRecommendation(for: ids[0]))
        model.selectAllVisible()
        model.splitSelectedGroup()
        XCTAssertNil(model.burstRecommendation(for: ids[0]))
        model.pickBurstPhoto(top.runnerUpID, from: top.winnerID)
        XCTAssertEqual(model.item(withID: top.runnerUpID)?.decision, .undecided)
    }

    @MainActor func testBurstColorEvidenceStaysOutOfCrossAlbumPreferences() async throws {
        let (model, root) = try await openBurst()
        let top = try XCTUnwrap(model.items.first.flatMap { model.burstRecommendation(for: $0.id) })
        model.pickBurstPhoto(top.winnerID, from: top.runnerUpID)
        XCTAssertTrue(model.flushPendingSaves())
        let io = WorkspaceIO(root: root.appendingPathComponent("State"))
        let global = try XCTUnwrap(io.read(GlobalWorkspaceDocument.self, at: io.globalURL))
        let example = try XCTUnwrap(global.examples.values.first)
        XCTAssertTrue(example.analysis.faces.allSatisfy { $0.surroundingColor == nil })
        XCTAssertNotNil(model.item(withID: top.winnerID)?.analysis?.faces.first?.surroundingColor)
    }

    @MainActor func testReopeningAnOlderAnalysisRefreshesFacesAndRetainsThePhotographersChoices() async throws {
        let (original, root) = try await openBurst()
        let first = try XCTUnwrap(original.selectedItem)
        original.setDecision(.pick, for: first.id)
        original.setRating(4)
        XCTAssertTrue(original.flushPendingSaves())
        let album = try XCTUnwrap(original.folder)
        let state = root.appendingPathComponent("State")
        let store = SessionStore(folder: album, baseDirectory: state.appendingPathComponent("Sessions"))
        var old: [String: PhotoAnalysis] = [:]
        for item in original.items {
            var analysis = try XCTUnwrap(item.analysis)
            analysis.version = 4
            for index in analysis.faces.indices { analysis.faces[index].surroundingColor = nil }
            let key = store.analysisKey(for: item).replacingOccurrences(of: "|v\(PhotoAnalysis.currentVersion)|", with: "|v4|")
            old[key] = analysis
        }
        try store.saveAnalysis(old)
        let fresh = try XCTUnwrap(first.analysis)
        let reopened = LibraryModel(appDataDirectory: state, defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                   analyze: { _, _ in fresh })
        reopened.scoring.shootingIntent = .groupPortrait
        await reopened.open(album)
        for _ in 0..<500 where reopened.isAnalyzing { try await Task.sleep(for: .milliseconds(10)) }
        let restored = try XCTUnwrap(reopened.item(withID: first.id))
        XCTAssertEqual(restored.decision, .pick)
        XCTAssertEqual(restored.rating, 4)
        XCTAssertNotNil(restored.analysis?.faces.first?.surroundingColor)
        XCTAssertNotNil(reopened.burstRecommendation(for: first.id))
        XCTAssertTrue(reopened.flushPendingSaves())
    }

    @MainActor func testSwitchingAlbumCannotReuseARecommendationOrCommitOldPick() async throws {
        let (model, root) = try await openBurst()
        let anchor = try XCTUnwrap(model.items.first)
        let top = try XCTUnwrap(model.burstRecommendation(for: anchor.id))
        let empty = root.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        await model.open(empty)
        XCTAssertNil(model.burstRecommendation(for: anchor.id))
        model.pickBurstPhoto(top.winnerID, from: anchor.id)
        XCTAssertFalse(model.canUndo)
        XCTAssertEqual(model.counts.total, 0)
    }
}
