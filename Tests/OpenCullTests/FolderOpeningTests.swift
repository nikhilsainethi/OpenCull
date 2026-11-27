import AppKit
import CullCore
import Foundation
import XCTest
@testable import OpenCull

private final class FolderScanGate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var ranOnMain = false
    private var timedOut = false
    private var enabled = false
    let release = DispatchSemaphore(value: 0)
    func scan() -> [PhotoItem] {
        lock.lock(); entered = true; ranOnMain = Thread.isMainThread; lock.unlock()
        let expired = release.wait(timeout: .now() + 10) != .success
        lock.lock(); timedOut = expired; lock.unlock()
        return []
    }
    var state: (entered: Bool, main: Bool, timedOut: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (entered, ranOnMain, timedOut)
    }
    func enable() { lock.lock(); enabled = true; lock.unlock() }
    var isEnabled: Bool { lock.lock(); defer { lock.unlock() }; return enabled }
}

final class FolderOpeningTests: XCTestCase {
    @MainActor private func waitUntilEntered(_ gate: FolderScanGate) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !gate.state.entered && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(gate.state.entered)
    }

    @MainActor func testBlockedFolderScanLeavesMainActorResponsive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenCull-opening-\(UUID().uuidString)")
        let gate = FolderScanGate()
        let model = LibraryModel(appDataDirectory: root, defaults: UserDefaults(suiteName: UUID().uuidString)!, scan: { _, _ in gate.scan() })
        defer { gate.release.signal(); _ = model.flushPendingSaves(); try? FileManager.default.removeItem(at: root) }
        let opening = Task { await model.open(root.appendingPathComponent("Photos")) }
        try await waitUntilEntered(gate)
        XCTAssertTrue(model.isOpening, "Opening must be visible while filesystem access is pending")
        XCTAssertFalse(gate.state.main, "FileProvider/TCC/slow media must not block the main actor")
        XCTAssertFalse(gate.state.timedOut, "The main actor must resume before the scan's safety timeout")
        XCTAssertNil(model.folder, "A pending scan must not partially install an album")
        gate.release.signal()
        await opening.value
        XCTAssertFalse(model.isOpening)
    }

    @MainActor func testLatestFolderRequestWinsEvenWhenOlderScanFinishesLater() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenCull-latest-open-\(UUID().uuidString)")
        let slow = root.appendingPathComponent("Slow"), latest = root.appendingPathComponent("Latest")
        let gate = FolderScanGate()
        let model = LibraryModel(appDataDirectory: root.appendingPathComponent("State"), defaults: UserDefaults(suiteName: UUID().uuidString)!, scan: { url, _ in
            url == slow ? gate.scan() : []
        })
        defer { gate.release.signal(); _ = model.flushPendingSaves(); try? FileManager.default.removeItem(at: root) }
        let older = Task { await model.open(slow) }
        try await waitUntilEntered(gate)
        await model.open(latest)
        XCTAssertEqual(model.folder, latest)
        XCTAssertFalse(model.isOpening)
        let newestAlert = model.alert?.id
        gate.release.signal()
        await older.value
        XCTAssertEqual(model.folder, latest)
        XCTAssertEqual(model.recentAlbums.first?.path, latest.path)
        XCTAssertEqual(model.alert?.id, newestAlert, "A superseded load must not overwrite the latest result or alert")
    }

    @MainActor func testCancelPendingOpenPreservesAlbumAndBlocksImportAndExport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenCull-cancel-open-\(UUID().uuidString)")
        let current = root.appendingPathComponent("Current"), slow = root.appendingPathComponent("Slow")
        let gate = FolderScanGate()
        let model = LibraryModel(appDataDirectory: root.appendingPathComponent("State"), defaults: UserDefaults(suiteName: UUID().uuidString)!, scan: { url, _ in
            url == slow ? gate.scan() : [PhotoItem(url: url.appendingPathComponent("photo.png"))]
        })
        defer { gate.release.signal(); _ = model.flushPendingSaves(); try? FileManager.default.removeItem(at: root) }
        await model.open(current)
        model.setDecision(.pick)
        let id = model.selectedID
        let pending = Task { await model.open(slow) }
        try await waitUntilEntered(gate)
        XCTAssertThrowsError(try model.beginPhotosImport())
        let destination = root.appendingPathComponent("MustNotExport")
        model.exportEdited(to: destination, format: .jpeg, quality: 0.9, maxPixelSize: nil, metadata: .preserve, allPicks: true)
        XCTAssertFalse(model.isExporting)
        model.copy(model.items, to: destination)
        XCTAssertFalse(model.isExporting)
        model.writeSidecars()
        XCTAssertFalse(model.isExporting)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let delegate = AppDelegate(); delegate.model = model
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
        XCTAssertFalse(model.isOpening, "Cancel must return immediately without waiting for blocked filesystem I/O")
        XCTAssertEqual(model.folder, current)
        gate.release.signal()
        await pending.value
        XCTAssertEqual(model.folder, current)
        XCTAssertEqual(model.selectedID, id)
        XCTAssertEqual(model.counts.picks, 1)
    }

    @MainActor func testFailedOpenPreservesAlbumAndUnsavedChoices() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenCull-failed-open-\(UUID().uuidString)")
        let current = root.appendingPathComponent("Current"), broken = root.appendingPathComponent("Broken")
        let model = LibraryModel(appDataDirectory: root.appendingPathComponent("State"), defaults: UserDefaults(suiteName: UUID().uuidString)!, scan: { url, _ in
            if url == broken { throw CocoaError(.fileReadNoSuchFile) }
            return [PhotoItem(url: url.appendingPathComponent("photo.png"))]
        })
        defer { _ = model.flushPendingSaves(); try? FileManager.default.removeItem(at: root) }
        await model.open(current)
        model.setDecision(.pick)
        var edit = EditRecipe(); edit.exposure = 1.5; model.setRecipe(edit)
        await model.open(broken)
        XCTAssertFalse(model.isOpening)
        XCTAssertEqual(model.folder, current)
        XCTAssertEqual(model.counts.picks, 1)
        XCTAssertEqual(model.selectedRecipe, edit)
        XCTAssertEqual(model.alert?.title, "Could not open folder")
    }

    @MainActor func testSameAlbumReloadCannotOverwriteChangesMadeWhileLoading() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("OpenCull-consistent-open-\(UUID().uuidString)")
        let photos = root.appendingPathComponent("Photos"), data = root.appendingPathComponent("State")
        try fm.createDirectory(at: photos, withIntermediateDirectories: true)
        try Data([0]).write(to: photos.appendingPathComponent("photo.jpg"))
        let store = SessionStore(folder: photos, baseDirectory: data.appendingPathComponent("Sessions"))
        let item = try XCTUnwrap(PhotoScanner.scan(folder: photos).first)
        let analysis = PhotoAnalysis(pixelWidth: 40, pixelHeight: 40, captureDate: nil, sharpness: 300, subjectSharpness: 300,
                                     meanLuminance: 0.5, highlightClipping: 0, shadowClipping: 0, faces: [])
        try store.saveAnalysis([store.analysisKey(for: item): analysis])
        let gate = FolderScanGate()
        let model = LibraryModel(appDataDirectory: data, defaults: UserDefaults(suiteName: UUID().uuidString)!, scan: { url, recursive in
            if gate.isEnabled { _ = gate.scan() }
            return try PhotoScanner.scan(folder: url, recursive: recursive)
        })
        defer { gate.release.signal(); _ = model.flushPendingSaves(); try? fm.removeItem(at: root) }
        await model.open(photos)
        model.setDecision(.pick)
        var edit = EditRecipe(); edit.exposure = 1.5; model.setRecipe(edit)
        XCTAssertTrue(model.flushPendingSaves())
        gate.enable()
        let reload = Task { await model.open(photos) }
        try await waitUntilEntered(gate)
        model.undo() // Also represents a pending auto-tone/aspect task completing during the load.
        XCTAssertEqual(model.selectedRecipe, .identity)
        model.undo()
        XCTAssertEqual(model.counts.picks, 0)
        gate.release.signal()
        await reload.value
        XCTAssertEqual(model.selectedRecipe, .identity, "The pre-load edit must not overwrite a newer workspace change")
        XCTAssertEqual(model.counts.picks, 0, "A cleared choice is absent from saved entries and must not be resurrected by a retry")
        XCTAssertTrue(model.flushPendingSaves())
        let persisted = try JSONDecoder().decode(WorkspaceDocument.self, from: Data(contentsOf: store.directory.appendingPathComponent("workspace.json")))
        XCTAssertEqual(persisted.records[store.key(for: item.url)]?.recipe, .identity)
        XCTAssertNil(try store.readDecisions()[store.key(for: item.url)])
    }
}
