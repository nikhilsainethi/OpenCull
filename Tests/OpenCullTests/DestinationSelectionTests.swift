import AppKit
import CullCore
import ImageIO
import XCTest
@testable import OpenCull

@MainActor private final class DestinationPanelProbe {
    var completions: [@MainActor (URL?) -> Void] = []
    var cancellations = 0
    func present(_ message: String, completion: @escaping @MainActor (URL?) -> Void) -> @MainActor () -> Void {
        completions.append(completion)
        return { self.cancellations += 1 }
    }
}

final class DestinationSelectionTests: XCTestCase {
    @MainActor private func model(_ probe: DestinationPanelProbe) -> LibraryModel {
        LibraryModel(appDataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                     defaults: UserDefaults(suiteName: UUID().uuidString)!, presentDestination: probe.present)
    }
    @MainActor private func until(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition())
    }
    @MainActor func testPendingDestinationLeavesMainActorResponsiveAndRejectsReentry() async throws {
        let probe = DestinationPanelProbe(), model = model(probe)
        let first = Task { await model.chooseDestination(message: "First") }
        try await until { probe.completions.count == 1 }
        XCTAssertTrue(model.isChoosingDestination)
        let second = Task { await model.chooseDestination(message: "Duplicate") }
        await Task.yield()
        XCTAssertEqual(probe.completions.count, 1, "A rapid default action must not open another panel")
        probe.completions.forEach { $0(nil) }
        let firstValue = await first.value, secondValue = await second.value
        XCTAssertNil(firstValue); XCTAssertNil(secondValue)
        XCTAssertFalse(model.isChoosingDestination)
    }
    @MainActor func testCancelResetsGuardAndLateCompletionCannotFinishNextPanel() async throws {
        let probe = DestinationPanelProbe(), model = model(probe)
        let first = Task { await model.chooseDestination(message: "First") }
        try await until { probe.completions.count == 1 }
        model.cancelDestinationSelection()
        let firstValue = await first.value
        XCTAssertNil(firstValue); XCTAssertFalse(model.isChoosingDestination)
        XCTAssertEqual(probe.cancellations, 1)
        let second = Task { await model.chooseDestination(message: "Second") }
        try await until { probe.completions.count == 2 }
        probe.completions[0](URL(fileURLWithPath: "/stale"))
        XCTAssertTrue(model.isChoosingDestination)
        let wanted = URL(fileURLWithPath: "/chosen")
        probe.completions[1](wanted)
        let result = await second.value
        XCTAssertEqual(result, wanted); XCTAssertFalse(model.isChoosingDestination)
    }
    @MainActor func testTaskCancellationClosesPanelAndResumesCaller() async throws {
        let probe = DestinationPanelProbe(), model = model(probe)
        let task = Task { await model.chooseDestination(message: "Cancel task") }
        try await until { model.isChoosingDestination }
        task.cancel()
        let result = await task.value
        XCTAssertNil(result); XCTAssertEqual(probe.cancellations, 1)
        XCTAssertFalse(model.isChoosingDestination)
    }
    @MainActor func testTerminationCancelsPendingDestination() async throws {
        let probe = DestinationPanelProbe(), model = model(probe)
        let task = Task { await model.chooseDestination(message: "Closing") }
        try await until { model.isChoosingDestination }
        let delegate = AppDelegate(); delegate.model = model
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
        let result = await task.value
        XCTAssertNil(result); XCTAssertFalse(model.isChoosingDestination)
        XCTAssertEqual(probe.cancellations, 1)
    }
    @MainActor func testSynchronousAndRepeatedCompletionResumesOnlyOnce() async throws {
        let wanted = URL(fileURLWithPath: "/chosen")
        let model = LibraryModel(appDataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                                 defaults: UserDefaults(suiteName: UUID().uuidString)!, presentDestination: { _, completion in
            completion(wanted)
            completion(nil)
            return {}
        })
        let result = await model.chooseDestination(message: "Immediate completion")
        XCTAssertEqual(result, wanted)
        XCTAssertFalse(model.isChoosingDestination)
        model.cancelDestinationSelection()
    }
    @MainActor private func workspace(_ probe: DestinationPanelProbe, raw: Bool = false) async throws -> (LibraryModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenCull-destination-\(UUID().uuidString)")
        let photos = root.appendingPathComponent("Photos"), data = root.appendingPathComponent("State")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        for i in 0..<2 {
            if raw {
                try Data([0, 1, 2]).write(to: photos.appendingPathComponent("photo\(i).CR3"))
                continue
            }
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 20, bitsPerSample: 8,
                                      samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
            for y in 0..<20 { for x in 0..<40 { rep.setColor(NSColor(calibratedRed: 0.6, green: 0.2, blue: 0.1, alpha: 1), atX: x, y: y) } }
            let url = photos.appendingPathComponent("photo\(i).png")
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            let metadata = CGImageMetadataCreateMutable()
            XCTAssertTrue(CGImageMetadataRegisterNamespaceForPrefix(metadata, "http://ns.adobe.com/xap/1.0/" as CFString, "xmp" as CFString, nil))
            XCTAssertTrue(CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Rating" as CFString, "-1" as CFString))
            XCTAssertTrue(CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Label" as CFString, "Red" as CFString))
            CGImageDestinationAddImageAndMetadata(destination, try XCTUnwrap(rep.cgImage), metadata, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        let store = SessionStore(folder: photos, baseDirectory: data.appendingPathComponent("Sessions"))
        let items = try PhotoScanner.scan(folder: photos)
        let facts = PhotoAnalysis(pixelWidth: 40, pixelHeight: 20, captureDate: nil, sharpness: 300, subjectSharpness: 300,
                                  meanLuminance: 0.5, highlightClipping: 0, shadowClipping: 0, faces: [])
        try store.saveAnalysis(Dictionary(uniqueKeysWithValues: items.map { (store.analysisKey(for: $0), facts) }))
        let model = LibraryModel(appDataDirectory: data, defaults: UserDefaults(suiteName: UUID().uuidString)!, presentDestination: probe.present)
        model.autoAdvance = false; await model.open(photos)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (model, root)
    }
    @MainActor func testDestinationSelectionBlocksAlbumImportAndCompetingExport() async throws {
        let probe = DestinationPanelProbe()
        let (model, root) = try await workspace(probe)
        let folder = model.folder
        let task = Task { await model.chooseDestination(message: "Pending") }
        try await until { model.isChoosingDestination }
        await model.open(root.appendingPathComponent("Other"))
        XCTAssertEqual(model.folder, folder); XCTAssertFalse(model.isOpening)
        XCTAssertThrowsError(try model.beginPhotosImport())
        model.copy(model.items, to: root.appendingPathComponent("MustNotCopy"))
        model.exportEdited(to: root.appendingPathComponent("MustNotRender"), format: .png, quality: 1,
                           maxPixelSize: nil, metadata: .remove, allPicks: false)
        model.writeSidecars()
        XCTAssertFalse(model.isExporting)
        model.cancelDestinationSelection(); _ = await task.value
        _ = model.flushPendingSaves()
    }
    @MainActor func testRenderedExportRetainsSelectionRecipeAndRatingFromBeforeChooser() async throws {
        let probe = DestinationPanelProbe()
        let (model, root) = try await workspace(probe)
        let first = model.items[0], second = model.items[1]
        model.select(first.id); model.setDecision(.pick); model.setRating(4)
        var crop = EditRecipe(); crop.crop = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        model.setRecipe(crop)
        let choosing = Task { await model.chooseAndExportEdited(format: .png, quality: 1, maxPixelSize: nil, metadata: .preserve, allPicks: false) }
        try await until { probe.completions.count == 1 }
        model.setRecipe(.identity); model.setRating(1); model.select(second.id)
        let destination = root.appendingPathComponent("Rendered")
        probe.completions[0](destination)
        let started = await choosing.value
        XCTAssertTrue(started)
        try await until { !model.isExporting }
        let files = try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
        let output = try XCTUnwrap(files.first { $0.pathExtension == "png" })
        XCTAssertTrue(output.lastPathComponent.hasPrefix("photo0"))
        let metadata = try XCTUnwrap(ImageLoader.metadata(url: output))
        XCTAssertEqual(metadata.pixelWidth, 20); XCTAssertEqual(metadata.pixelHeight, 20)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let embedded = try XCTUnwrap(CGImageSourceCopyMetadataAtIndex(source, 0, nil))
        let rating = CGImageMetadataCopyStringValueWithPath(embedded, nil, "xmp:Rating" as CFString) as String?
        XCTAssertEqual(rating, "4")
        _ = model.flushPendingSaves()
    }
    @MainActor func testCopyPicksRetainsChoicesCapturedBeforeChooser() async throws {
        let probe = DestinationPanelProbe()
        let (model, root) = try await workspace(probe, raw: true)
        let first = model.items[0], second = model.items[1]
        model.select(first.id); model.setDecision(.pick); model.setRating(4)
        model.copyPicks()
        try await until { probe.completions.count == 1 }
        model.setDecision(.reject); model.setRating(1)
        model.select(second.id); model.setDecision(.pick)
        let destination = root.appendingPathComponent("Copies")
        probe.completions[0](destination)
        try await until { model.alert?.title == "Originals copied" || model.alert?.title == "Copy needs attention" }
        let output = destination.appendingPathComponent(first.fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path), model.alert?.message ?? "No export result")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(second.fileName).path))
        let metadata = try String(contentsOf: XMPSidecar.sidecarURL(for: output), encoding: .utf8)
        XCTAssertTrue(metadata.contains("xmp:Rating=\"4\""))
        XCTAssertTrue(metadata.contains("xmp:Label=\"Green\""))
        _ = model.flushPendingSaves()
    }
    @MainActor func testTerminationAfterPanelAcceptCannotStartQueuedExport() async throws {
        let probe = DestinationPanelProbe()
        let (model, root) = try await workspace(probe)
        let choosing = Task { await model.chooseAndExportEdited(format: .png, quality: 1, maxPixelSize: nil, metadata: .remove, allPicks: false) }
        try await until { probe.completions.count == 1 }
        let destination = root.appendingPathComponent("MustNotRenderAfterQuit")
        probe.completions[0](destination)
        let delegate = AppDelegate(); delegate.model = model
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
        let started = await choosing.value
        XCTAssertFalse(started, "Quit must invalidate a panel result whose export continuation has not resumed")
        XCTAssertFalse(model.isExporting)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        _ = model.flushPendingSaves()
    }
    @MainActor func testChangedSourceWhileChoosingDoesNotRender() async throws {
        let probe = DestinationPanelProbe()
        let (model, root) = try await workspace(probe)
        let photo = try XCTUnwrap(model.selectedItem)
        let choosing = Task { await model.chooseAndExportEdited(format: .png, quality: 1, maxPixelSize: nil, metadata: .remove, allPicks: false) }
        try await until { probe.completions.count == 1 }
        try Data([0]).write(to: photo.url)
        let destination = root.appendingPathComponent("MustNotRender")
        probe.completions[0](destination)
        let started = await choosing.value
        XCTAssertFalse(started); XCTAssertFalse(model.isExporting)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(model.alert?.title, "Photos changed since review")
        _ = model.flushPendingSaves()
    }
}
