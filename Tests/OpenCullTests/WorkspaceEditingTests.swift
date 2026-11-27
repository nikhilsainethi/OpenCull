import AppKit
import CullCore
import ImageIO
import XCTest
@testable import OpenCull

final class WorkspaceEditingTests: XCTestCase {
    @MainActor private func workspace(count: Int = 3) throws -> (LibraryModel, URL, URL, UserDefaults) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenCull-edit-workflow-\(UUID().uuidString)")
        let photos = root.appendingPathComponent("Photos"), data = root.appendingPathComponent("State")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        for i in 0..<count {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 48, bitsPerSample: 8,
                                      samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
            for y in 0..<48 { for x in 0..<48 { rep.setColor(NSColor(calibratedRed: CGFloat(x + 16) / 80, green: CGFloat(y + 16) / 80, blue: 0.4, alpha: 1), atX: x, y: y) } }
            try rep.representation(using: .png, properties: [:])!.write(to: photos.appendingPathComponent("photo\(i).png"))
        }
        let store = SessionStore(folder: photos, baseDirectory: data.appendingPathComponent("Sessions"))
        var cache: [String: PhotoAnalysis] = [:]
        for (i, item) in try PhotoScanner.scan(folder: photos).enumerated() {
            cache[store.analysisKey(for: item)] = PhotoAnalysis(pixelWidth: 48, pixelHeight: 48, captureDate: Date(timeIntervalSince1970: Double(i * 30)),
                sharpness: 300, subjectSharpness: 300, meanLuminance: count > 3 ? 0.1 + Float(i) * 0.7 / Float(count - 1) : 0.5,
                highlightClipping: 0, shadowClipping: 0, faces: [], labels: ["landscape", "mountain"])
        }
        try store.saveAnalysis(cache)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let model = LibraryModel(appDataDirectory: data, defaults: defaults)
        model.autoAdvance = false; model.open(photos)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (model, photos, data, defaults)
    }

    @MainActor func testEditBatchUndoRedoAndReload() throws {
        let (model, photos, data, defaults) = try workspace()
        let first = try XCTUnwrap(model.selectedItem)
        let original = try Data(contentsOf: first.url)
        var edit = EditRecipe(); edit.exposure = 1.25; edit.crop = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        model.setRecipe(edit, name: "Exposure and crop")
        XCTAssertEqual(model.selectedRecipe, edit)
        model.selectAllVisible(); model.applyEditToSelection()
        XCTAssertTrue(model.items.allSatisfy { model.recipe(for: $0) == edit })
        model.undo()
        XCTAssertEqual(model.recipe(for: model.items[1]), .identity)
        model.redo()
        XCTAssertEqual(model.recipe(for: model.items[1]), edit)
        XCTAssertTrue(model.flushPendingSaves())
        let reopened = LibraryModel(appDataDirectory: data, defaults: defaults)
        reopened.open(photos)
        XCTAssertTrue(reopened.items.allSatisfy { reopened.recipe(for: $0) == edit })
        XCTAssertEqual(try Data(contentsOf: first.url), original)
        _ = reopened.flushPendingSaves()
    }

    @MainActor func testBulkChoicesUndoAsOneAction() throws {
        let (model, _, _, _) = try workspace()
        model.selectAllVisible(); model.setDecision(.pick)
        XCTAssertEqual(model.counts.picks, 3)
        model.undo(); XCTAssertEqual(model.counts.undecided, 3)
        model.redo(); XCTAssertEqual(model.counts.picks, 3)
        _ = model.flushPendingSaves()
    }

    @MainActor func testSearchByVisionLabelMaintainsVisibleSelection() throws {
        let (model, _, _, _) = try workspace()
        model.searchText = "mountain"
        XCTAssertEqual(model.visibleItems.count, 3)
        model.searchText = "no such subject"
        XCTAssertTrue(model.visibleItems.isEmpty)
        XCTAssertNil(model.selectedItem)
        model.setDecision(.pick)
        XCTAssertEqual(model.counts.picks, 0)
        _ = model.flushPendingSaves()
    }

    @MainActor func testReplacedPhotoDoesNotInheritChoicesOrEdits() throws {
        let (model, photos, data, defaults) = try workspace()
        let first = try XCTUnwrap(model.selectedItem)
        model.setDecision(.pick)
        var edit = EditRecipe(); edit.exposure = 2
        model.setRecipe(edit)
        XCTAssertTrue(model.flushPendingSaves())
        try Data([0, 1, 2, 3, 4]).write(to: first.url)
        let reopened = LibraryModel(appDataDirectory: data, defaults: defaults)
        reopened.open(photos)
        let changed = try XCTUnwrap(reopened.items.first { $0.id == first.id })
        XCTAssertEqual(changed.decision, .undecided)
        XCTAssertEqual(reopened.recipe(for: changed), .identity)
        _ = reopened.flushPendingSaves()
    }

    @MainActor func testSaveFailureLeavesWorkDirtyAndObservable() throws {
        let (_, photos, data, defaults) = try workspace()
        let blocked = data.deletingLastPathComponent().appendingPathComponent("blocked")
        try Data([0]).write(to: blocked)
        let model = LibraryModel(appDataDirectory: blocked, defaults: defaults)
        model.open(photos); model.setDecision(.pick)
        XCTAssertFalse(model.flushPendingSaves())
        XCTAssertEqual(model.saveStatus, "Save failed")
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertEqual(model.counts.picks, 1)
    }

    @MainActor func testLocalStyleAndManualGroupsPersist() throws {
        let (model, photos, data, defaults) = try workspace()
        var edit = EditRecipe(); edit.contrast = 1.2
        model.setRecipe(edit); model.saveStyle(name: "Everyday")
        model.selectAllVisible(); model.mergeSelectedGroup()
        XCTAssertEqual(Set(model.items.compactMap(\.groupID)).count, 1)
        XCTAssertTrue(model.flushPendingSaves())
        let reopened = LibraryModel(appDataDirectory: data, defaults: defaults)
        reopened.open(photos)
        XCTAssertEqual(reopened.styles.last?.name, "Everyday")
        XCTAssertEqual(reopened.styles.last?.recipe, edit)
        XCTAssertEqual(Set(reopened.items.compactMap(\.groupID)).count, 1)
        reopened.splitSelectedGroup()
        XCTAssertEqual(reopened.selectedItem?.groupSize, 1)
        _ = reopened.flushPendingSaves()
    }

    @MainActor func testUndoChoiceStillClearsEarlierXMPExport() async throws {
        let (model, _, _, _) = try workspace()
        let photo = try XCTUnwrap(model.selectedItem)
        model.setDecision(.pick)
        model.writeSidecars()
        for _ in 0..<300 where model.isExporting { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isExporting)
        let url = XMPSidecar.sidecarURL(for: photo.url)
        let picked = try XMLDocument(contentsOf: url)
        XCTAssertEqual(try picked.nodes(forXPath: "//@*[local-name()='Rating']").first?.stringValue, "1")
        model.undo()
        XCTAssertEqual(model.selectedItem?.decision, .undecided)
        model.writeSidecars()
        for _ in 0..<300 where model.isExporting { try await Task.sleep(for: .milliseconds(10)) }
        let cleared = try XMLDocument(contentsOf: url)
        XCTAssertTrue(try cleared.nodes(forXPath: "//@*[local-name()='Rating'] | //*[local-name()='Rating']").isEmpty)
        XCTAssertTrue(try cleared.nodes(forXPath: "//@*[local-name()='Label'] | //*[local-name()='Label']").isEmpty)
        _ = model.flushPendingSaves()
    }

    @MainActor func testAutoToneKeepsCompositionColorAndDetail() async throws {
        let (model, _, _, _) = try workspace()
        var edit = EditRecipe()
        edit.exposure = 3; edit.rotation = 90; edit.crop = CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.7)
        edit.temperature = 7800; edit.vibrance = 0.2; edit.sharpness = 0.8; edit.contrast = 1.2
        model.setRecipe(edit)
        model.autoAdjust()
        for _ in 0..<300 where model.selectedRecipe.exposure == 3 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotEqual(model.selectedRecipe.exposure, 3)
        XCTAssertEqual(model.selectedRecipe.crop, edit.crop)
        XCTAssertEqual(model.selectedRecipe.rotation, edit.rotation)
        XCTAssertEqual(model.selectedRecipe.temperature, edit.temperature)
        XCTAssertEqual(model.selectedRecipe.vibrance, edit.vibrance)
        XCTAssertEqual(model.selectedRecipe.sharpness, edit.sharpness)
        XCTAssertEqual(model.selectedRecipe.contrast, edit.contrast)
        model.undo(); XCTAssertEqual(model.selectedRecipe, edit)
        _ = model.flushPendingSaves()
    }

    @MainActor func testRenderedExportUsesCompanionAndCurrentEmbeddedChoices() async throws {
        let (model, photos, _, _) = try workspace()
        let source = photos.appendingPathComponent("photo0.png")
        let raw = photos.appendingPathComponent("A.CR3"), jpeg = photos.appendingPathComponent("A.JPG")
        let rep = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: source)))
        try rep.representation(using: .jpeg, properties: [.compressionFactor: 0.95])!.write(to: jpeg)
        let badRaw = Data([0, 1, 2]); try badRaw.write(to: raw)
        model.open(photos)
        let rawItem = try XCTUnwrap(model.items.first { $0.fileName == "A.CR3" })
        model.select(rawItem.id)
        XCTAssertEqual(model.selectedItem?.fileName, "A.CR3")
        model.setDecision(.pick); model.setRating(5)
        var edit = EditRecipe(); edit.exposure = 1; model.setRecipe(edit)
        let destination = photos.deletingLastPathComponent().appendingPathComponent("Export")
        model.exportEdited(to: destination, format: .jpeg, quality: 0.9, maxPixelSize: nil, metadata: .preserve, allPicks: true)
        for _ in 0..<500 where model.isExporting { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isExporting)
        let files = try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil).filter { !$0.lastPathComponent.hasPrefix(".") }
        XCTAssertEqual(files.count, 1)
        let output = try XCTUnwrap(files.first)
        let encoded = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let metadata = try XCTUnwrap(CGImageSourceCopyMetadataAtIndex(encoded, 0, nil))
        XCTAssertEqual(CGImageMetadataCopyStringValueWithPath(metadata, nil, "xmp:Rating" as CFString) as String?, "5")
        XCTAssertTrue(model.alert?.message.contains("companion") == true, model.alert?.message ?? "No export summary")
        XCTAssertEqual(try Data(contentsOf: raw), badRaw)
        _ = model.flushPendingSaves()
    }

    @MainActor func testPreferenceCapUsesRecentChoicesRatherThanFileNames() throws {
        let (_, _, data, defaults) = try workspace()
        let a = PhotoAnalysis(pixelWidth: 48, pixelHeight: 48, captureDate: nil, sharpness: 300, subjectSharpness: 300,
                              meanLuminance: 0.5, highlightClipping: 0, shadowClipping: 0, faces: [])
        var examples: [String: PreferenceExample] = [:]
        for i in 0..<4 { examples["z-old\(i)"] = PreferenceExample(analysis: a, decision: .reject, rating: 0, updated: .distantPast) }
        for i in 0..<600 { examples["a-new\(i)"] = PreferenceExample(analysis: a, decision: .pick, rating: 0, updated: Date(timeIntervalSince1970: Double(i))) }
        let io = WorkspaceIO(root: data)
        try io.write(GlobalWorkspaceDocument(examples: examples), at: io.globalURL)
        let model = LibraryModel(appDataDirectory: data, defaults: defaults)
        XCTAssertEqual(model.preference.sampleCount, 600)
        XCTAssertEqual(model.preference.rejectCount, 0)
        XCTAssertFalse(model.preference.isReady)
    }

    @MainActor func testPickingComparedPhotoPreservesComparisonSelection() throws {
        let (model, _, _, _) = try workspace()
        model.selectAllVisible(); model.mode = .compare
        let ids = model.selection
        let id = try XCTUnwrap(model.comparisonItems.last?.id)
        model.setDecision(.pick, for: id)
        XCTAssertEqual(model.mode, .compare)
        XCTAssertEqual(model.selection, ids)
        XCTAssertEqual(model.comparisonItems.count, 3)
        XCTAssertEqual(model.items.first { $0.id == id }?.decision, .pick)
        _ = model.flushPendingSaves()
    }

    @MainActor func testPhotosImportStreamsCopiesWithIndependentNames() async throws {
        let (model, photos, _, _) = try workspace()
        let data = try Data(contentsOf: photos.appendingPathComponent("photo0.png"))
        let album = try model.beginPhotosImport()
        XCTAssertTrue(model.isImporting)
        try LibraryModel.storeImportedImage(data, index: 0, in: album)
        try LibraryModel.storeImportedImage(data, index: 1, in: album)
        XCTAssertThrowsError(try LibraryModel.storeImportedImage(data, index: 0, in: album))
        model.finishPhotosImport(album)
        XCTAssertFalse(model.isImporting)
        XCTAssertEqual(model.items.count, 2)
        XCTAssertEqual(try Data(contentsOf: model.items[0].url), data)
        _ = model.flushPendingSaves()
    }

    @MainActor func testLearnedStyleAdaptsBatchPreservesCompositionAndReloads() throws {
        let (model, photos, data, defaults) = try workspace(count: 8)
        let ids = model.items.map(\.id)
        var originalEdits: [String: EditRecipe] = [:]
        for id in ids {
            model.select(id)
            var edit = EditRecipe()
            edit.exposure = 2 - Double(model.selectedItem!.analysis!.meanLuminance) * 2
            if id == ids[0] { edit.crop = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8); edit.rotation = 90 }
            model.setRecipe(edit); originalEdits[id] = edit
        }
        model.selectAllVisible()
        model.mergeSelectedGroup()
        model.setDecision(.pick)
        XCTAssertEqual(model.adaptiveExampleCount, 8)
        model.saveAdaptiveStyle(name: "General light")
        let style = try XCTUnwrap(model.styles.last)
        XCTAssertEqual(style.profile?.sampleCount, 8)
        model.applyAdaptiveStyle(style, allPicks: true)
        let first = try XCTUnwrap(model.items.first { $0.id == ids[0] })
        let last = try XCTUnwrap(model.items.first { $0.id == ids[7] })
        XCTAssertGreaterThan(model.recipe(for: first).exposure, model.recipe(for: last).exposure)
        XCTAssertEqual(model.recipe(for: first).crop, originalEdits[first.id]?.crop)
        XCTAssertEqual(model.recipe(for: first).rotation, 90)
        model.undo()
        XCTAssertEqual(model.recipe(for: first), originalEdits[first.id])
        XCTAssertTrue(model.flushPendingSaves())
        let reopened = LibraryModel(appDataDirectory: data, defaults: defaults)
        reopened.open(photos)
        XCTAssertEqual(reopened.styles.last?.profile, style.profile)
        _ = reopened.flushPendingSaves()
    }

    @MainActor func testChangedFileCannotReceiveEarlierChoicesOrEditsOnExport() throws {
        let (model, photos, data, _) = try workspace()
        let original = try XCTUnwrap(model.selectedItem)
        model.setDecision(.pick)
        var edit = EditRecipe(); edit.exposure = 1; model.setRecipe(edit)
        XCTAssertTrue(model.flushPendingSaves())
        let store = SessionStore(folder: photos, baseDirectory: data.appendingPathComponent("Sessions"))
        let before = store.fingerprint(for: original)
        let replacement = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 48, bitsPerSample: 8,
                                          samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
                                          bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<48 { for x in 0..<48 { replacement.setColor(.blue, atX: x, y: y) } }
        let bytes = replacement.representation(using: .png, properties: [:])!
        try bytes.write(to: original.url, options: .atomic)
        XCTAssertNotEqual(before, store.fingerprint(for: original))
        model.writeSidecars()
        XCTAssertEqual(model.alert?.title, "Photos changed since review")
        XCTAssertFalse(FileManager.default.fileExists(atPath: XMPSidecar.sidecarURL(for: original.url).path))
        let destination = photos.deletingLastPathComponent().appendingPathComponent("must-not-export")
        model.copy([original], to: destination)
        XCTAssertFalse(model.isExporting)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        model.exportEdited(to: destination, format: .jpeg, quality: 0.9, maxPixelSize: nil, metadata: .preserve, allPicks: true)
        XCTAssertFalse(model.isExporting)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: original.url), bytes)
    }
}
