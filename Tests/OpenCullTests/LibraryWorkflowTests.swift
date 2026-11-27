import AppKit
import CullCore
import XCTest
@testable import OpenCull

final class LibraryWorkflowTests: XCTestCase {
    @MainActor private func fixture(cached: Int = 3) throws -> (URL, SessionStore) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OpenCull-workflow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for i in 0..<3 { try Data([0]).write(to: folder.appendingPathComponent("img\(i).jpg")) }
        let store = SessionStore(folder: folder)
        let photos = try PhotoScanner.scan(folder: folder)
        var cache: [String: PhotoAnalysis] = [:]
        for (i, photo) in photos.prefix(cached).enumerated() {
            cache[store.analysisKey(for: photo)] = PhotoAnalysis(pixelWidth: 100, pixelHeight: 100,
                captureDate: Date(timeIntervalSince1970: Double(i) * 30), sharpness: 300, subjectSharpness: 300,
                meanLuminance: 0.5, highlightClipping: 0, shadowClipping: 0, faces: [])
        }
        try store.saveAnalysis(cache)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: store.directory)
        }
        return (folder, store)
    }

    @MainActor func testFilterAlwaysSelectsAVisiblePhoto() throws {
        let (folder, _) = try fixture()
        let model = LibraryModel()
        model.open(folder)
        model.selectedID = model.items[0].id
        model.setDecision(.pick)
        model.selectedID = model.items[1].id
        model.setDecision(.reject)
        model.selectedID = model.items[1].id
        model.filter = .picks
        XCTAssertEqual(model.selectedID, model.visibleItems.first?.id)
        XCTAssertEqual(model.selectedItem?.decision, .pick)
    }

    @MainActor func testLogicalGroupNavigationAdvancesAcrossSingletons() throws {
        let (folder, _) = try fixture()
        let model = LibraryModel()
        model.open(folder)
        model.selectNextSection()
        XCTAssertEqual(model.selectedID, model.items[1].id)
        model.showGroups = false
        model.selectNextSection()
        XCTAssertEqual(model.selectedID, model.items[2].id)
        model.selectPreviousSection()
        XCTAssertEqual(model.selectedID, model.items[1].id)
    }

    @MainActor func testAcceptSuggestionsCannotCommitPartialAnalysis() throws {
        let (folder, _) = try fixture(cached: 1)
        let model = LibraryModel()
        model.open(folder)
        XCTAssertTrue(model.isAnalyzing)
        model.acceptSuggestions()
        XCTAssertEqual(model.counts.picks, 0)
        XCTAssertEqual(model.counts.rejects, 0)
    }

    @MainActor func testFailedOpenPreservesCurrentAnalysis() throws {
        let (folder, _) = try fixture(cached: 0)
        let model = LibraryModel()
        model.open(folder)
        XCTAssertTrue(model.isAnalyzing)
        model.open(folder.appendingPathComponent("missing"))
        XCTAssertTrue(model.isAnalyzing)
        XCTAssertEqual(model.folder, folder)
    }
}

final class PreviewCacheTests: XCTestCase {
    func testPreviewIdentityIsStableForTheSameRecipe() throws {
        let item = PhotoItem(url: URL(fileURLWithPath: "/tmp/preview-key.png"))
        var recipe = EditRecipe(); recipe.exposure = 1
        let keys = (0..<50).map { _ in PreviewCache.versionKey(for: item, size: 1000, recipe: recipe) }
        XCTAssertEqual(Set(keys).count, 1)
    }

    func testReplacementInvalidatesPreview() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OpenCull-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("test.png")
        func write(_ color: NSColor) throws {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 40, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            color.setFill(); NSRect(x: 0, y: 0, width: 40, height: 40).fill()
            NSGraphicsContext.restoreGraphicsState()
            try rep.representation(using: .png, properties: [:])!.write(to: url)
        }
        try write(.red)
        let firstItem = try PhotoScanner.scan(folder: folder)[0]
        let firstLoaded = await PreviewCache.shared.image(for: firstItem, size: 100)
        let first = try XCTUnwrap(firstLoaded)
        try write(.blue)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 3)], ofItemAtPath: url.path)
        let secondItem = try PhotoScanner.scan(folder: folder)[0]
        let secondLoaded = await PreviewCache.shared.image(for: secondItem, size: 100)
        let second = try XCTUnwrap(secondLoaded)
        XCTAssertNotEqual(first.dataProvider!.data! as Data, second.dataProvider!.data! as Data)
    }
}
