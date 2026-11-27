import Foundation
import XCTest
@testable import CullCore

final class PersistenceVersionSafetyTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenCull-version-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func recovery(_ store: SessionStore) throws -> URL {
        do { _ = try store.readDecisions(); XCTFail("Expected corrupt decisions to be rejected") }
        catch let error as SessionStore.ReadError { return try XCTUnwrap(error.recoveryCopy) }
        throw CocoaError(.fileReadCorruptFile)
    }

    func testEveryCorruptDecisionVersionGetsItsOwnCurrentRecoveryCopy() throws {
        let root = try directory()
        let store = SessionStore(folder: root.appendingPathComponent("Photos"), baseDirectory: root.appendingPathComponent("Sessions"))
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let source = store.directory.appendingPathComponent("decisions.json")
        let first = Data("{first damaged choices".utf8), second = Data("{newer damaged choices containing different work".utf8)
        try first.write(to: source)
        let firstRecovery = try recovery(store)
        try store.saveDecisions(["A.CR3": .init(decision: .pick, rating: 5)])
        try second.write(to: source)
        let secondRecovery = try recovery(store)
        XCTAssertNotEqual(firstRecovery, secondRecovery)
        XCTAssertEqual(try Data(contentsOf: firstRecovery), first)
        XCTAssertEqual(try Data(contentsOf: secondRecovery), second)
        try store.saveDecisions([:])
        XCTAssertEqual(try Data(contentsOf: secondRecovery), second, "A later save must not erase the latest recovery data")
    }

    func testCopyRejectsChangedInputBeforeStaging() throws {
        let root = try directory(), source = root.appendingPathComponent("A.CR3"), destination = root.appendingPathComponent("Export")
        let original = Data([1, 2, 3]); try original.write(to: source)
        var item = PhotoItem(url: source); item.decision = .pick
        let result = Exporter.copy([item], to: destination, validator: { _ in false })
        XCTAssertEqual(result.copiedPhotos, 0)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testCopyRevalidatesStagedBundleBeforePublishing() throws {
        let root = try directory(), source = root.appendingPathComponent("A.CR3"), destination = root.appendingPathComponent("Export")
        let original = Data([1, 2, 3]); try original.write(to: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let unrelated = destination.appendingPathComponent("existing.txt")
        try Data([8]).write(to: unrelated)
        var item = PhotoItem(url: source); item.decision = .pick
        let calls = ValidationCalls()
        let result = Exporter.copy([item], to: destination, validator: { _ in calls.increment() == 1 })
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(result.copiedPhotos, 0)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), ["existing.txt"])
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: unrelated), Data([8]))
    }

    func testCopyPublishesOnlyAfterBothVersionChecksPass() throws {
        let root = try directory(), source = root.appendingPathComponent("A.CR3"), destination = root.appendingPathComponent("Export")
        try Data([1, 2, 3]).write(to: source)
        var item = PhotoItem(url: source); item.decision = .pick
        let calls = ValidationCalls()
        let result = Exporter.copy([item], to: destination, validator: { _ in _ = calls.increment(); return true })
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(result.copiedPhotos, 1)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("A.CR3").path))
    }
}

private final class ValidationCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}
