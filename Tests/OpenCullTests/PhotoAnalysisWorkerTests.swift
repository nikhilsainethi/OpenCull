import CullCore
import Foundation
import XCTest
@testable import OpenCull

private func workerFacts() -> PhotoAnalysis {
    PhotoAnalysis(pixelWidth: 24, pixelHeight: 24, captureDate: nil, sharpness: 300,
        subjectSharpness: 300, meanLuminance: 0.5, highlightClipping: 0, shadowClipping: 0, faces: [])
}

private final class BlockingPhotoProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = 0, completed = 0, active = 0, peak = 0
    private var outsideTask = true, outsideMain = true
    let release = DispatchSemaphore(value: 0)
    func analyze() throws -> PhotoAnalysis {
        let hasTask = withUnsafeCurrentTask { $0 != nil }
        lock.lock()
        entered += 1; active += 1; peak = max(peak, active)
        outsideTask = outsideTask && !hasTask; outsideMain = outsideMain && !Thread.isMainThread
        lock.unlock()
        defer { lock.lock(); active -= 1; completed += 1; lock.unlock() }
        guard release.wait(timeout: .now() + 3) == .success else { throw CocoaError(.userCancelled) }
        return workerFacts()
    }
    var state: (entered: Int, completed: Int, peak: Int, outsideTask: Bool, outsideMain: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (entered, completed, peak, outsideTask, outsideMain)
    }
    func releaseAll(_ count: Int = 16) { for _ in 0..<count { release.signal() } }
}

private final class PhotoCallFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func mark() { lock.lock(); calls += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
}

final class PhotoAnalysisWorkerTests: XCTestCase {
    @MainActor private func until(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(3)) }
        XCTAssertTrue(condition(), "Blocking work must leave the main actor and cooperative executor available")
    }

    @MainActor func testBlockingAnalysisHasNoSwiftTaskAndLeavesMainActorResponsive() async throws {
        let worker = PhotoAnalysisWorker(maxConcurrentOperations: 1), probe = BlockingPhotoProbe()
        defer { probe.releaseAll() }
        let job = Task { await worker.run { try probe.analyze() } }
        try await until { probe.state.entered == 1 }
        XCTAssertTrue(probe.state.outsideTask, "Vision's synchronous dispatch waits must not occupy a cooperative Swift worker")
        XCTAssertTrue(probe.state.outsideMain)
        let responsive = await Task.detached { 42 }.value
        XCTAssertEqual(responsive, 42, "Other async file/import work must continue while Vision is blocked")
        probe.releaseAll()
        let result = await job.value
        XCTAssertNoThrow(try result.get())
    }

    @MainActor func testWorkerEnforcesOneBudgetAcrossConcurrentRequestGroups() async throws {
        let worker = PhotoAnalysisWorker(maxConcurrentOperations: 2), probe = BlockingPhotoProbe()
        defer { probe.releaseAll() }
        let jobs = (0..<8).map { _ in Task { await worker.run { try probe.analyze() } } }
        try await until { probe.state.entered >= 2 }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(probe.state.peak, 2, "Old and new request groups must share the same bounded queue")
        probe.releaseAll()
        for job in jobs { let result = await job.value; XCTAssertNoThrow(try result.get()) }
        XCTAssertEqual(probe.state.completed, 8)
    }

    @MainActor func testCancelledQueuedAnalysisResumesWithoutCallingAnalyzer() async throws {
        let worker = PhotoAnalysisWorker(maxConcurrentOperations: 1), probe = BlockingPhotoProbe(), cancelledCall = PhotoCallFlag()
        defer { probe.releaseAll() }
        let blocking = Task { await worker.run { try probe.analyze() } }
        try await until { probe.state.entered == 1 }
        let queued = Task { await worker.run { cancelledCall.mark(); return workerFacts() } }
        for _ in 0..<10 { await Task.yield() }
        queued.cancel()
        let start = Date()
        let result = await queued.value
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "Queued cancellation must not wait for the active Vision request")
        if case .failure(let error) = result { XCTAssertTrue(error is CancellationError) }
        else { XCTFail("Cancelled queued work must report cancellation") }
        XCTAssertEqual(cancelledCall.count, 0)
        probe.releaseAll()
        _ = await blocking.value
        _ = await worker.run { workerFacts() } // Drain the old queued operation too.
        XCTAssertEqual(cancelledCall.count, 0)
    }

    @MainActor func testCancellingRunningAnalysisReturnsOnceAndKeepsSlotUntilWorkEnds() async throws {
        let worker = PhotoAnalysisWorker(maxConcurrentOperations: 1), probe = BlockingPhotoProbe(), nextCall = PhotoCallFlag()
        defer { probe.releaseAll() }
        let running = Task { await worker.run { try probe.analyze() } }
        try await until { probe.state.entered == 1 }
        running.cancel()
        let result = await running.value
        if case .failure(let error) = result { XCTAssertTrue(error is CancellationError) }
        else { XCTFail("The cancelled caller must finish without waiting on synchronous analysis") }
        let next = Task { await worker.run { nextCall.mark(); return workerFacts() } }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(nextCall.count, 0, "Cancellation cannot release the physical worker slot while Vision still runs")
        probe.releaseAll()
        let nextResult = await next.value
        XCTAssertNoThrow(try nextResult.get())
        XCTAssertEqual(probe.state.completed, 1)
        XCTAssertEqual(nextCall.count, 1, "Late completion must not resume the cancelled continuation twice")
    }

    @MainActor func testDifferentLibrariesUseTheSharedNoncooperativeWorkerBudget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenCull-worker-models-\(UUID().uuidString)")
        let probe = BlockingPhotoProbe()
        defer { probe.releaseAll(); try? FileManager.default.removeItem(at: root) }
        var models: [LibraryModel] = []
        for index in 0..<2 {
            let photos = root.appendingPathComponent("Photos\(index)")
            try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
            for photo in 0..<6 { try Data([1]).write(to: photos.appendingPathComponent("photo\(photo).jpg")) }
            let model = LibraryModel(appDataDirectory: root.appendingPathComponent("State\(index)"), defaults: UserDefaults(suiteName: UUID().uuidString)!,
                analyze: { _, _ in try probe.analyze() })
            models.append(model)
            await model.open(photos)
        }
        let limit = PhotoAnalysisWorker.shared.maxConcurrentOperations
        try await until { probe.state.entered >= limit }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(probe.state.outsideTask, "LibraryModel must use the shared blocking-worker boundary")
        XCTAssertLessThanOrEqual(probe.state.peak, limit, "Separate libraries and superseded albums cannot multiply the global Vision budget")
        probe.releaseAll(20)
        try await until { models.allSatisfy { !$0.isAnalyzing } }
        XCTAssertEqual(probe.state.completed, 12)
        for model in models { XCTAssertTrue(model.flushPendingSaves()) }
    }
}
