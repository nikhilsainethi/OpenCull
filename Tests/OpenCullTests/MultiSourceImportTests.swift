import AppKit
import CullCore
import XCTest
@testable import OpenCull

final class MultiSourceImportTests: XCTestCase {
    private func fixture() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenCull-sources-\(UUID().uuidString)")
        let source = root.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 24, pixelsHigh: 24,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let image = source.appendingPathComponent("Original name.png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: image)
        return (root, image)
    }
    @MainActor func testFileImportCopiesOriginalAndRestoresSourceOnReopen() async throws {
        let (root, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = try Data(contentsOf: source)
        let state = root.appendingPathComponent("State")
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let model = LibraryModel(appDataDirectory: state, defaults: defaults)
        await model.importFiles([source], source: .googlePhotos)
        XCTAssertFalse(model.isImporting)
        let album = try XCTUnwrap(model.folder)
        XCTAssertNotEqual(album, source.deletingLastPathComponent())
        let photo = try XCTUnwrap(model.items.first)
        XCTAssertEqual(try Data(contentsOf: photo.url), bytes)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(model.provenance(for: photo)?.source, .googlePhotos)
        XCTAssertEqual(model.provenance(for: photo)?.originalFileName, source.lastPathComponent)
        XCTAssertTrue(model.flushPendingSaves())
        let reopened = LibraryModel(appDataDirectory: state, defaults: defaults)
        await reopened.open(album)
        XCTAssertEqual(reopened.provenance(for: try XCTUnwrap(reopened.items.first))?.source, .googlePhotos)
    }
    @MainActor func testRejectedRemoteImportPreservesCurrentAlbumAndEdits() async throws {
        let (root, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = LibraryModel(appDataDirectory: root.appendingPathComponent("State"), defaults: UserDefaults(suiteName: UUID().uuidString)!)
        await model.open(source.deletingLastPathComponent())
        model.autoAdvance = false; model.setDecision(.pick)
        var recipe = EditRecipe(); recipe.exposure = 1; model.setRecipe(recipe)
        let current = model.folder
        await model.importFiles([URL(string: "https://photos.google.com/photo/private")!], source: .googlePhotos)
        XCTAssertEqual(model.folder, current)
        XCTAssertEqual(model.counts.picks, 1)
        XCTAssertEqual(model.selectedRecipe, recipe)
        XCTAssertFalse(model.isImporting)
        XCTAssertEqual(model.alert?.title, "Could not import photos")
    }
    @MainActor func testCancelledPickerImportNeverOpensItsStagingFolder() async throws {
        let (root, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = LibraryModel(appDataDirectory: root.appendingPathComponent("State"), defaults: UserDefaults(suiteName: UUID().uuidString)!)
        await model.open(source.deletingLastPathComponent())
        let old = model.folder
        let staging = try model.beginPhotosImport()
        try LibraryModel.storeImportedImage(Data(contentsOf: source), index: 0, in: staging)
        model.cancelImport()
        await model.finishPhotosImport(staging)
        XCTAssertEqual(model.folder, old)
        XCTAssertFalse(model.isImporting)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }
    @MainActor func testStalePickerFailureCannotClearNewBatch() async throws {
        let (root, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = LibraryModel(appDataDirectory: root.appendingPathComponent("State"), defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let first = try model.beginPhotosImport()
        model.cancelImport()
        let second = try model.beginPhotosImport()
        await model.finishPhotosImport(nil)
        XCTAssertTrue(model.isImporting, "An ownerless completion must not clear another batch")
        let foreign = root.appendingPathComponent("Source")
        await model.finishPhotosImport(foreign)
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path), "Only owned scratch can be deleted")
        XCTAssertTrue(model.isImporting)
        await model.finishPhotosImport(nil, expectedStaging: first)
        XCTAssertTrue(model.isImporting)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        await model.finishPhotosImport(nil, expectedStaging: second)
        XCTAssertFalse(model.isImporting)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }

    @MainActor func testLateDropReceiptCannotReplaceOrUnlockNewImport() async throws {
        let (root, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = LibraryModel(appDataDirectory: root.appendingPathComponent("State"), defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let first = UUID(), second = UUID()
        XCTAssertTrue(model.beginDropReceipt(first))
        XCTAssertFalse(model.canImport)
        XCTAssertThrowsError(try model.beginPhotosImport())
        model.cancelImport()
        XCTAssertTrue(model.beginDropReceipt(second))
        XCTAssertFalse(model.finishDropReceipt(first))
        XCTAssertTrue(model.isImporting)
        XCTAssertTrue(model.finishDropReceipt(second))
        XCTAssertTrue(model.canImport)
    }

    @MainActor func testTakeoutDateSurvivesReopenWithCanonicalScannerURLs() async throws {
        let (root, image) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{\"title\":\"Original name.png\",\"photoTakenTime\":{\"timestamp\":\"1609459200\"}}".utf8)
            .write(to: image.appendingPathExtension("json"))
        let state = root.appendingPathComponent("State")
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let model = LibraryModel(appDataDirectory: state, defaults: defaults, analyze: { _, _ in
            PhotoAnalysis(pixelWidth: 24, pixelHeight: 24, captureDate: nil, sharpness: 300, subjectSharpness: 300,
                meanLuminance: 0.5, highlightClipping: 0, shadowClipping: 0, faces: [])
        }, scan: { url, recursive in
            try PhotoScanner.scan(folder: url, recursive: recursive).map {
                PhotoItem(url: $0.url.resolvingSymlinksInPath(), companions: $0.companions,
                    fileSize: $0.fileSize, modificationDate: $0.modificationDate)
            }
        })
        await model.importFiles([image.deletingLastPathComponent()], source: .takeout)
        let deadline = Date().addingTimeInterval(3)
        while model.isAnalyzing && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let item = try XCTUnwrap(model.items.first)
        XCTAssertEqual(model.provenance(for: item)?.originalFileName, image.lastPathComponent)
        XCTAssertEqual(item.analysis?.captureDate, Date(timeIntervalSince1970: 1609459200))
        let album = try XCTUnwrap(model.folder)
        XCTAssertTrue(model.flushPendingSaves())
        await model.open(album)
        XCTAssertFalse(model.isAnalyzing, "Raw measurements should be cached and dates reapplied from the manifest")
        XCTAssertEqual(model.items.first?.analysis?.captureDate, Date(timeIntervalSince1970: 1609459200))
    }

}
