import Foundation

/// Counts one view's work in flight on other threads and queues: layouts
/// that are waiting or running, results that main has not installed yet,
/// and pictures, formulas and code colors that are loading. Any thread.
///
/// Each piece of work calls `begin()` before it hands off and `end()` once
/// it is done, after it has begun whatever it leads to. The count therefore
/// reaches zero only when nothing is left to do.
final class PendingWork: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var onIdle: (@Sendable () -> Void)?

    /// Nothing is in flight.
    var isIdle: Bool { lock.withLock { count == 0 } }

    /// Sets what to call, on the thread that ends the last piece of work,
    /// when the count drops to zero. Nil to call nothing.
    func setOnIdle(_ onIdle: (@Sendable () -> Void)?) {
        lock.withLock { self.onIdle = onIdle }
    }

    func begin() {
        lock.withLock { count += 1 }
    }

    func end() {
        let handler: (@Sendable () -> Void)? = lock.withLock {
            precondition(count > 0, "PendingWork.end() without a begin()")
            count -= 1
            return count == 0 ? onIdle : nil
        }
        handler?()
    }
}
