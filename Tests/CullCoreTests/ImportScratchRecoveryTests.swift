import CullCore
import Foundation
import XCTest

final class ImportScratchRecoveryTests: XCTestCase {
    func testRecoveryRemovesOnlyMarkedDeadProcessScratch() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("OpenCull-recovery-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let dead = root.appendingPathComponent(".opencull-import-dead")
        let live = root.appendingPathComponent(".opencull-import-live")
        let unmarked = root.appendingPathComponent(".opencull-import-unknown")
        let original = root.appendingPathComponent("Originals")
        for url in [dead, live, unmarked, original] { try fm.createDirectory(at: url, withIntermediateDirectories: false) }
        let marker = "OpenCull import scratch v1\n2147483647\n"
        try Data(marker.utf8).write(to: dead.appendingPathComponent(ImportScratchRecovery.markerName))
        try Data(marker.utf8).write(to: original.appendingPathComponent(ImportScratchRecovery.markerName))
        try ImportScratchRecovery.mark(live)
        let link = root.appendingPathComponent(".opencull-import-link")
        try fm.createSymbolicLink(at: link, withDestinationURL: original)
        ImportScratchRecovery.recover(in: root, prefixes: [".opencull-import-"])
        XCTAssertFalse(fm.fileExists(atPath: dead.path))
        for url in [live, unmarked, original, link] { XCTAssertTrue(fm.fileExists(atPath: url.path)) }
        try ImportScratchRecovery.unmark(live)
        XCTAssertFalse(fm.fileExists(atPath: live.appendingPathComponent(ImportScratchRecovery.markerName).path))
    }
}
