import Foundation

/// A lock-guarded cancellation signal for blocking work that runs off the
/// Swift cooperative pool, where `Task.isCancelled` is not observable.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}
