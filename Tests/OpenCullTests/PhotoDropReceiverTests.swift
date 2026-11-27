import AppKit
import XCTest
@testable import OpenCull

final class PhotoDropReceiverTests: XCTestCase {
    func testPromiseRepresentationTakesPriorityOverBrowserURL() {
        XCTAssertEqual(PhotoDropPolicy.classify(hasPromises: true, localURLs: [], hasRemoteRepresentation: true), .promises)
    }

    func testLocalFileBatchKeepsOrderAndRemovesDuplicatePaths() {
        let first = URL(fileURLWithPath: "/tmp/one.jpg")
        let second = URL(fileURLWithPath: "/tmp/two.raw")
        XCTAssertEqual(PhotoDropPolicy.classify(hasPromises: false, localURLs: [first, second, first], hasRemoteRepresentation: false), .files([first, second]))
    }

    func testRemoteURLIsNeverTreatedAsLocalFile() {
        XCTAssertEqual(PhotoDropPolicy.classify(hasPromises: false, localURLs: [URL(string: "https://photos.google.com/a.jpg")!], hasRemoteRepresentation: true), .unsupported)
        XCTAssertEqual(PhotoDropPolicy.classify(hasPromises: false, localURLs: [], hasRemoteRepresentation: false), .unsupported)
    }

    func testExcessiveBatchesAreRejectedRatherThanSilentlyTruncated() {
        let urls = (0...PhotoDropPolicy.maximumFiles).map { URL(fileURLWithPath: "/tmp/\($0).jpg") }
        XCTAssertEqual(PhotoDropPolicy.classify(hasPromises: false, localURLs: urls, hasRemoteRepresentation: false), .tooManyFiles)
    }

    func testCleanupOnlyRemovesOwnedTemporaryDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenCull-drop-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let file = root.appendingPathComponent("sample.jpg")
        try Data([1, 2, 3]).write(to: file)
        PhotoDropPayload(urls: [file], ownedTemporaryDirectory: nil).cleanup()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let payload = PhotoDropPayload(urls: [file], ownedTemporaryDirectory: root)
        payload.cleanup(); payload.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testPromiseBatchFinishesOnceOnlyAfterEveryPromisedFileArrives() {
        let root = URL(fileURLWithPath: "/tmp/promise-destination", isDirectory: true)
        let batch = PhotoPromiseBatch(expectedCount: 2, directory: root)
        XCTAssertNil(batch.accept(root.appendingPathComponent("one.jpg"), error: nil))
        let result = batch.accept(root.appendingPathComponent("two.jpg"), error: nil)
        XCTAssertEqual(try? result?.get().urls.count, 2)
        XCTAssertNil(batch.accept(root.appendingPathComponent("late.jpg"), error: nil))
    }

    func testPromiseErrorDiscardsPartialBatchAndDoesNotExposeOutsideFiles() {
        let root = URL(fileURLWithPath: "/tmp/promise-destination", isDirectory: true)
        let batch = PhotoPromiseBatch(expectedCount: 2, directory: root)
        XCTAssertNil(batch.accept(root.appendingPathComponent("one.jpg"), error: nil))
        let result = batch.accept(URL(fileURLWithPath: "/tmp/private.jpg"), error: nil)
        switch result {
        case .failure?: break
        default: XCTFail("An out-of-destination file promise must fail the entire batch")
        }
    }

    func testUnsealedPromiseCallbacksWaitForActualFilenameCount() {
        let root = URL(fileURLWithPath: "/tmp/promise-destination", isDirectory: true)
        let batch = PhotoPromiseBatch(directory: root)
        XCTAssertNil(batch.accept(root.appendingPathComponent("one.jpg"), error: nil))
        XCTAssertNil(batch.seal(expectedCount: 2))
        XCTAssertEqual(try? batch.accept(root.appendingPathComponent("two.jpg"), error: nil)?.get().urls.count, 2)
    }

    func testCancellationAndMalformedPromiseCountAreOneShotFailures() {
        let root = URL(fileURLWithPath: "/tmp/promise-destination", isDirectory: true)
        let batch = PhotoPromiseBatch(expectedCount: 2, directory: root)
        XCTAssertNotNil(batch.fail("cancelled"))
        XCTAssertNil(batch.accept(root.appendingPathComponent("one.jpg"), error: nil))
        XCTAssertNil(batch.fail("cancelled again"))
        let unknown = PhotoPromiseBatch(directory: root)
        XCTAssertThrowsError(try unknown.seal(expectedCount: 0)?.get())
    }

    func testPromisedSymlinkCannotExposeFileOutsideDestination() throws {
        let manager = FileManager.default
        let parent = manager.temporaryDirectory.appendingPathComponent("OpenCull-drop-symlink-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: parent) }
        let root = parent.appendingPathComponent("received", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = parent.appendingPathComponent("private.jpg")
        try Data([1]).write(to: outside)
        let link = root.appendingPathComponent("misleading.jpg")
        try manager.createSymbolicLink(at: link, withDestinationURL: outside)
        let batch = PhotoPromiseBatch(expectedCount: 1, directory: root)
        XCTAssertThrowsError(try batch.accept(link, error: nil)?.get())
    }

    @MainActor func testRejectedReceiptDoesNotCreateTemporaryDirectory() {
        let surface = PhotoDropDestinationView()
        var requested: [UUID] = []
        surface.onReceiving = { requested.append($0); return false }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OpenCull-denied-drop-\(UUID().uuidString)")
        XCTAssertNil(surface.beginReceiving(in: directory))
        XCTAssertEqual(requested.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    @MainActor func testCancellationIDReleasesOnlyItsReceiptAndIgnoresQueuedOldCompletion() throws {
        let surface = PhotoDropDestinationView()
        var requested: [UUID] = [], ended: [UUID] = [], delivered: [PhotoDropPayload] = []
        var failures: [String] = []
        surface.onReceiving = { requested.append($0); return true }
        surface.onReceiptEnded = { ended.append($0) }
        surface.onFiles = { delivered.append($0) }
        surface.onFailure = { failures.append($0) }
        let directoryA = FileManager.default.temporaryDirectory.appendingPathComponent("OpenCull-receipt-a-\(UUID().uuidString)")
        let first = try XCTUnwrap(surface.beginReceiving(in: directoryA))
        XCTAssertNil(first.seal(expectedCount: 1))
        let queuedResult = try XCTUnwrap(first.accept(directoryA.appendingPathComponent("first.jpg"), error: nil))
        surface.cancellationID = UUID()
        XCTAssertEqual(ended, [requested[0]])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directoryA.path))
        let directoryB = FileManager.default.temporaryDirectory.appendingPathComponent("OpenCull-receipt-b-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directoryB) }
        let second = try XCTUnwrap(surface.beginReceiving(in: directoryB))
        surface.finish(queuedResult, for: first)
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertEqual(ended, [requested[0]])
        surface.isEnabled = false // The model reserves the import while this receipt is pending.
        XCTAssertNil(second.seal(expectedCount: 1))
        let result = try XCTUnwrap(second.accept(directoryB.appendingPathComponent("second.jpg"), error: nil))
        surface.finish(result, for: second)
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.receiptID, requested[1])
        XCTAssertEqual(ended, [requested[0]], "Success transfers the receipt to onFiles instead of releasing it early")
        XCTAssertTrue(failures.isEmpty, "User cancellation is silent")
    }

    @MainActor func testPromiseFailureReleasesReceiptAndCleansOwnedFolderOnce() throws {
        let surface = PhotoDropDestinationView()
        var requested: UUID?, ended: [UUID] = [], failures: [String] = []
        surface.onReceiving = { requested = $0; return true }
        surface.onReceiptEnded = { ended.append($0) }
        surface.onFailure = { failures.append($0) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OpenCull-receipt-error-\(UUID().uuidString)")
        let batch = try XCTUnwrap(surface.beginReceiving(in: directory))
        let error = try XCTUnwrap(batch.fail("Source cancelled delivery"))
        surface.finish(error, for: batch)
        surface.finish(error, for: batch)
        XCTAssertEqual(ended, [try XCTUnwrap(requested)])
        XCTAssertEqual(failures, ["Source cancelled delivery"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    @MainActor func testCancelledProviderLateOutputIsCleanedWithoutTouchingNewReceipt() throws {
        let manager = FileManager.default
        let surface = PhotoDropDestinationView()
        let oldDirectory = manager.temporaryDirectory.appendingPathComponent("OpenCull-late-old-\(UUID().uuidString)")
        let newDirectory = manager.temporaryDirectory.appendingPathComponent("OpenCull-late-new-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: oldDirectory); try? manager.removeItem(at: newDirectory) }
        let oldBatch = try XCTUnwrap(surface.beginReceiving(in: oldDirectory))
        XCTAssertNil(oldBatch.seal(expectedCount: 2))
        surface.cancelPendingDrop()
        let newBatch = try XCTUnwrap(surface.beginReceiving(in: newDirectory))
        _ = newBatch // Keep the new receipt pending during late delivery.
        try manager.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
        let lateFile = oldDirectory.appendingPathComponent("late.jpg")
        try Data([1, 2]).write(to: lateFile)
        XCTAssertNil(oldBatch.accept(lateFile, error: nil))
        XCTAssertFalse(manager.fileExists(atPath: oldDirectory.path), "Cancelled providers can finish writing after cancellation")
        XCTAssertTrue(manager.fileExists(atPath: newDirectory.path))
        surface.cancelPendingDrop()
    }

    func testFailedProviderLateOutputIsCleanedButSuccessfulPayloadKeepsCallerOwnership() throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("OpenCull-late-failure-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: directory) }
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        let failed = PhotoPromiseBatch(expectedCount: 2, directory: directory)
        XCTAssertNotNil(failed.fail("delivery failed"))
        let file = directory.appendingPathComponent("late.jpg")
        try Data([1]).write(to: file)
        XCTAssertNil(failed.accept(file, error: nil))
        XCTAssertFalse(manager.fileExists(atPath: directory.path))
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data([2]).write(to: file)
        let successful = PhotoPromiseBatch(expectedCount: 1, directory: directory)
        let result = try XCTUnwrap(successful.accept(file, error: nil))
        XCTAssertNil(successful.accept(file, error: nil))
        XCTAssertTrue(manager.fileExists(atPath: file.path), "Success transfers cleanup ownership to the importer")
        (try result.get()).cleanup()
    }

    @MainActor func testDropSurfacePassesNormalClicksToUnderlyingContent() {
        let surface = PhotoDropDestinationView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let content = NSView(frame: surface.bounds)
        surface.addSubview(content)
        XCTAssertTrue(surface.hitTest(NSPoint(x: 100, y: 100)) === content)
    }
}
