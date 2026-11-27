import CoreGraphics
import CullCore
import Foundation
import ImageIO
import XCTest
@testable import OpenCull

private final class AnalysisWorkerGate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    let release = DispatchSemaphore(value: 0)

    func markEntered() {
        lock.lock(); entered = true; lock.unlock()
    }

    var hasEntered: Bool {
        lock.lock(); defer { lock.unlock() }
        return entered
    }
}

final class AnalysisIdentityTests: XCTestCase {
    @MainActor func testChangedInputCannotReceiveOrCacheOldAnalysis() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("OpenCull-Analysis-Identity-\(UUID().uuidString)")
        let photos = root.appendingPathComponent("Photos"), data = root.appendingPathComponent("State")
        try fm.createDirectory(at: photos, withIntermediateDirectories: true)
        let photo = photos.appendingPathComponent("input.png")
        func writePNG(width: Int, red: CGFloat) throws {
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: 24, bitsPerComponent: 8, bytesPerRow: width * 4,
                                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.setFillColor(red: red, green: 0.4, blue: 0.5, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: 24))
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(photo as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        try writePNG(width: 32, red: 0.2)
        let suite = "OpenCull-Analysis-Identity-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let gate = AnalysisWorkerGate()
        defer { gate.release.signal() }
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suite)
            try? fm.removeItem(at: root)
        }
        let measuredOriginal = PhotoAnalysis(pixelWidth: 32, pixelHeight: 24, captureDate: nil, sharpness: 300,
                                            subjectSharpness: 300, meanLuminance: 0.5, highlightClipping: 0, shadowClipping: 0, faces: [])
        let model = LibraryModel(appDataDirectory: data, defaults: defaults, analyze: { _, _ in
            gate.markEntered()
            guard gate.release.wait(timeout: .now() + 10) == .success else { throw CocoaError(.userCancelled) }
            return measuredOriginal
        })
        let store = SessionStore(folder: photos, baseDirectory: data.appendingPathComponent("Sessions"))
        let originalKey = store.analysisKey(for: try XCTUnwrap(PhotoScanner.scan(folder: photos).first))
        await model.open(photos)
        XCTAssertTrue(model.isAnalyzing)

        // Yield the MainActor while waiting for the background worker to enter its gate.
        let enteredDeadline = Date().addingTimeInterval(5)
        while !gate.hasEntered && Date() < enteredDeadline { try await Task.sleep(for: .milliseconds(10)) }
        guard gate.hasEntered else { XCTFail("The injected analysis worker did not start"); return }
        try writePNG(width: 64, red: 0.8)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 1)], ofItemAtPath: photo.path)
        let replacement = try XCTUnwrap(PhotoScanner.scan(folder: photos).first)
        let replacementKey = store.analysisKey(for: replacement)
        XCTAssertNotEqual(originalKey, replacementKey)
        gate.release.signal()

        let finishedDeadline = Date().addingTimeInterval(5)
        while model.isAnalyzing && Date() < finishedDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isAnalyzing, "Analysis must reach its terminal state after rejecting a changed input")
        let result = try XCTUnwrap(model.items.first)
        XCTAssertNil(result.analysis, "Measurements of the old pixels must never be shown for the replacement")
        XCTAssertTrue(result.analysisError?.localizedCaseInsensitiveContains("changed") == true)
        let cache = try store.readAnalysis()
        XCTAssertNil(cache[replacementKey], "Old measurements must not poison the replacement's versioned cache")
        XCTAssertTrue(cache.isEmpty)
        XCTAssertTrue(model.flushPendingSaves())
    }
}
