import CullCore
import Foundation

/// Enforce the managed-import limits while a system picker is still delivering data,
/// before writing a staging file (not after downloading the entire selection).
struct PhotoSelectionBudget {
    private let limits: PhotoImportLimits
    private let expectedCount: Int
    private(set) var receivedBytes: Int64 = 0
    private(set) var receivedCount = 0

    init(selectionCount: Int, limits: PhotoImportLimits = .default) throws {
        guard selectionCount > 0, selectionCount <= min(5_000, limits.maxEntries),
              limits.maxExpandedBytes > 0, limits.maxFileBytes > 0 else { throw PhotoImportError.limitExceeded }
        expectedCount = selectionCount; self.limits = limits
    }

    mutating func receive(byteCount: Int) throws {
        guard byteCount > 0, receivedCount < expectedCount,
              Int64(byteCount) <= limits.maxFileBytes,
              receivedBytes <= limits.maxExpandedBytes - Int64(byteCount) else { throw PhotoImportError.limitExceeded }
        receivedBytes += Int64(byteCount); receivedCount += 1
    }
}
