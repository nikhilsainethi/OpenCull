import CullCore
import XCTest
@testable import OpenCull

final class PhotoSelectionBudgetTests: XCTestCase {
    func testAggregateBudgetRejectsBeforeNextStagingWriteAndKeepsAccounting() throws {
        var budget = try PhotoSelectionBudget(selectionCount: 3,
            limits: PhotoImportLimits(maxEntries: 10, maxExpandedBytes: 100, maxFileBytes: 80))
        try budget.receive(byteCount: 60)
        XCTAssertThrowsError(try budget.receive(byteCount: 50))
        XCTAssertEqual(budget.receivedBytes, 60)
        XCTAssertEqual(budget.receivedCount, 1)
        try budget.receive(byteCount: 40)
        XCTAssertEqual(budget.receivedBytes, 100)
    }
    func testPerFileCountAndInvalidDeliveryLimits() throws {
        XCTAssertThrowsError(try PhotoSelectionBudget(selectionCount: 5_001))
        var budget = try PhotoSelectionBudget(selectionCount: 1,
            limits: PhotoImportLimits(maxEntries: 2, maxExpandedBytes: 100, maxFileBytes: 50))
        XCTAssertThrowsError(try budget.receive(byteCount: -1))
        XCTAssertThrowsError(try budget.receive(byteCount: 0))
        XCTAssertThrowsError(try budget.receive(byteCount: 51))
        try budget.receive(byteCount: 50)
        XCTAssertThrowsError(try budget.receive(byteCount: 1))
    }
}
