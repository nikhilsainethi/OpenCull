import CullCore
import Foundation
import XCTest
@testable import OpenCull

final class RecursiveAlbumPersistenceTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let album: URL
        let state: URL
        let top: URL
        let nested: URL
        let store: SessionStore
        let defaults: UserDefaults
    }

    @MainActor private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenCull-recursive-persistence-\(UUID().uuidString)")
        let album = root.appendingPathComponent("Album"), state = root.appendingPathComponent("State")
        let top = album.appendingPathComponent("top.jpg")
        let nested = album.appendingPathComponent("Nested/photo.jpg")
        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The scanner only needs regular files. Cached facts keep this test focused
        // on real persistence and file identity without invoking image analysis.
        try Data([1, 2, 3]).write(to: top)
        try Data([4, 5, 6]).write(to: nested)
        let store = SessionStore(folder: album, baseDirectory: state.appendingPathComponent("Sessions"))
        try cacheAnalyses(in: album, store: store)
        return Fixture(root: root, album: album, state: state, top: top, nested: nested, store: store,
                       defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    private func cacheAnalyses(in album: URL, store: SessionStore) throws {
        let photos = try PhotoScanner.scan(folder: album, recursive: true)
        var cache: [String: PhotoAnalysis] = [:]
        for (index, photo) in photos.enumerated() {
            cache[store.analysisKey(for: photo)] = PhotoAnalysis(pixelWidth: 100, pixelHeight: 100,
                captureDate: Date(timeIntervalSince1970: Double(index) * 30), sharpness: 300, subjectSharpness: 300,
                meanLuminance: 0.5, highlightClipping: 0, shadowClipping: 0, faces: [])
        }
        try store.saveAnalysis(cache)
    }

    @MainActor func testNestedChoicesAndEditsSurviveFlatReopenWithoutResurrectingClearedChoices() async throws {
        let fixture = try fixture()
        let model = LibraryModel(appDataDirectory: fixture.state, defaults: fixture.defaults)
        defer { _ = model.flushPendingSaves(); try? FileManager.default.removeItem(at: fixture.root) }
        model.autoAdvance = false
        model.recursive = true
        await model.open(fixture.album)
        XCTAssertEqual(model.items.count, 2)
        XCTAssertFalse(model.isAnalyzing)
        let top = try XCTUnwrap(model.items.first { $0.fileName == "top.jpg" })
        let nested = try XCTUnwrap(model.items.first { $0.fileName == "photo.jpg" })

        model.select(top.id)
        model.setDecision(.reject)
        model.setRating(3)
        var topEdit = EditRecipe(); topEdit.exposure = -0.75
        model.setRecipe(topEdit)
        model.select(nested.id)
        model.setDecision(.pick)
        model.setRating(4)
        var nestedEdit = EditRecipe(); nestedEdit.exposure = 1.25; nestedEdit.rotation = 90
        nestedEdit.crop = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        model.setRecipe(nestedEdit)
        model.splitSelectedGroup()
        let nestedGroup = try XCTUnwrap(model.records[nested.id]?.manualGroup)
        XCTAssertTrue(model.flushPendingSaves())

        model.recursive = false
        await model.open(fixture.album)
        XCTAssertEqual(model.items.map(\.id), [top.id])
        // Updating a visible record must replace its saved value, including clears.
        model.setDecision(.undecided)
        model.setRating(0)
        model.setRecipe(.identity)
        XCTAssertTrue(model.flushPendingSaves())

        model.recursive = true
        await model.open(fixture.album)
        let restored = try XCTUnwrap(model.items.first { $0.id == nested.id })
        XCTAssertEqual(restored.decision, .pick, "An unscanned subfolder is not permission to delete its saved choices")
        XCTAssertEqual(restored.rating, 4)
        XCTAssertEqual(model.recipe(for: restored), nestedEdit)
        XCTAssertEqual(model.records[nested.id]?.manualGroup, nestedGroup)
        let cleared = try XCTUnwrap(model.items.first { $0.id == top.id })
        XCTAssertEqual(cleared.decision, .undecided)
        XCTAssertEqual(cleared.rating, 0)
        XCTAssertEqual(model.recipe(for: cleared), .identity)
        XCTAssertTrue(model.flushPendingSaves())
    }

    @MainActor func testReplacedOmittedNestedFileDoesNotInheritRetainedChoicesOrEdits() async throws {
        let fixture = try fixture()
        let model = LibraryModel(appDataDirectory: fixture.state, defaults: fixture.defaults)
        defer { _ = model.flushPendingSaves(); try? FileManager.default.removeItem(at: fixture.root) }
        model.autoAdvance = false
        model.recursive = true
        await model.open(fixture.album)
        let nested = try XCTUnwrap(model.items.first { $0.fileName == "photo.jpg" })
        model.select(nested.id)
        model.setDecision(.pick)
        model.setRating(5)
        var edit = EditRecipe(); edit.exposure = 2
        model.setRecipe(edit)
        model.splitSelectedGroup()
        XCTAssertTrue(model.flushPendingSaves())

        model.recursive = false
        await model.open(fixture.album)
        XCTAssertTrue(model.flushPendingSaves())
        // Replacement while omitted must still invalidate retained file identity.
        try Data([7, 8, 9, 10, 11, 12]).write(to: fixture.nested)
        try cacheAnalyses(in: fixture.album, store: fixture.store)
        model.recursive = true
        await model.open(fixture.album)
        XCTAssertFalse(model.isAnalyzing)
        let replacement = try XCTUnwrap(model.items.first { $0.id == nested.id })
        XCTAssertEqual(replacement.decision, .undecided)
        XCTAssertEqual(replacement.rating, 0)
        XCTAssertEqual(model.recipe(for: replacement), .identity)
        XCTAssertNil(model.records[replacement.id]?.manualGroup)
    }
}
