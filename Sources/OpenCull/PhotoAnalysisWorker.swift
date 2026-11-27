import CullCore
import Foundation

/// Vision performs synchronous dispatch-group waits internally. Running those
/// waits on Swift's cooperative executor can starve unrelated async file/import
/// work on small machines. One process-wide blocking queue also keeps cancelled
/// or superseded albums from multiplying the physical analysis worker budget.
final class PhotoAnalysisWorker: @unchecked Sendable {
    static let shared = PhotoAnalysisWorker(maxConcurrentOperations: max(1, min(4, ProcessInfo.processInfo.activeProcessorCount - 2)))
    let maxConcurrentOperations: Int
    private let queue: OperationQueue

    init(maxConcurrentOperations: Int) {
        self.maxConcurrentOperations = max(1, maxConcurrentOperations)
        queue = OperationQueue()
        queue.name = "OpenCull blocking photo analysis"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = self.maxConcurrentOperations
    }

    func run(_ analyze: @escaping @Sendable () throws -> PhotoAnalysis) async -> Result<PhotoAnalysis, Error> {
        let request = AnalysisRequest()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard request.install(continuation) else { return }
                queue.addOperation {
                    // This closure has no Swift task context. Cancellation is
                    // explicit shared state, not Task.isCancelled on a GCD worker.
                    guard request.begin() else { return }
                    let result = autoreleasepool { Result { try analyze() } }
                    request.finish(result)
                }
            }
        }, onCancel: { request.cancel() })
    }
}

/// A queued/running request resumes its caller exactly once. Cancellation does
/// not cancel BlockOperation itself: a cancelled queued body must still check
/// the state, while an already-running Vision call retains its physical slot
/// until it returns. Its late result cannot resume the cancelled caller again.
private final class AnalysisRequest: @unchecked Sendable {
    typealias Outcome = Result<PhotoAnalysis, Error>
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var cancelled = false
    private var finished = false

    func install(_ continuation: CheckedContinuation<Outcome, Never>) -> Bool {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(returning: .failure(CancellationError()))
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !cancelled && !finished
    }

    func finish(_ result: Outcome) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let callback = continuation; continuation = nil
        lock.unlock()
        callback?.resume(returning: result)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        guard !finished else { lock.unlock(); return }
        finished = true
        let callback = continuation; continuation = nil
        lock.unlock()
        callback?.resume(returning: .failure(CancellationError()))
    }
}
