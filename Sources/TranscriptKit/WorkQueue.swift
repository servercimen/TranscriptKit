import Foundation

/// The queues that parse and lay out text in the background.
///
/// Each stream and each view has its own serial queue, so its work runs in
/// order. A serial queue without a target gets a new thread when it has
/// work, however many other queues are busy, so a screen that replaces many
/// documents at once can hold one thread for each. These queues target the
/// global queue instead, and share the pool that GCD keeps at about one
/// thread for each processor core. One view's long layout uses one thread
/// of the pool.
///
/// When more queues have work than the pool has threads, the queues wait in
/// turn, oldest first. Short work that a person waits to see, such as the
/// parse and layout of streamed text, does not wait in that line: `async`
/// with `urgent` gives it the QoS of the main thread with `.enforceQoS`, and
/// GCD gives work at that QoS a thread at once. Without `.enforceQoS`, the
/// QoS of the queue wins and the work waits. Long work stays at the lower
/// QoS. The work of one queue still runs in order: an urgent item raises
/// the QoS of the work queued before it on the same queue.
///
/// The target is the global queue itself, not a concurrent queue of our
/// own: when the main thread calls `sync` on a queue with work waiting for a
/// thread of a busy pool, GCD gives that work a thread at once only when the
/// queue targets the global queue directly. Through a queue of our own, the
/// main thread and urgent work wait until the pool is free. A `sync` call
/// does not wait for the work of other queues, but it still waits for the
/// work that is already on its own queue.
///
/// GCD starts more threads when a thread of the pool waits, for example
/// while Core Text loads a font the first time. So the pool alone does not
/// limit the threads: in the first burst after launch, each queue can get a
/// thread again. `asyncLong` sets a hard limit for long layouts: at most one
/// for each core runs at a time. The other long work waits outside its queue
/// and does not ask GCD for a thread, so GCD has nothing to start threads
/// for. A long layout that waits keeps its place in the limit.
///
/// Work on these queues must not wait for work on another of them, as
/// `sync` does: a thread that waits does no work, and GCD then starts more
/// threads.
enum WorkQueue {
    /// Text up to this length, in UTF-16 units, takes about a millisecond
    /// or less to parse or lay out.
    static let shortLength = 2_000

    /// A serial queue for one stream or view, on the shared pool.
    static func serial(label: String) -> DispatchQueue {
        DispatchQueue(label: label, qos: .userInitiated, target: .global(qos: .userInitiated))
    }

    /// At most this many items of long work run at a time.
    static let longWorkLimit = max(2, ProcessInfo.processInfo.activeProcessorCount)

    private static let longWork = Limit(count: longWorkLimit)

    /// Runs long `work` on `queue` after `delay` seconds, when fewer than
    /// `longWorkLimit` items of long work run. Until then, the work waits
    /// outside `queue`, oldest first, and holds no thread.
    ///
    /// A `sync` call on `queue` can run before work that waits for the
    /// limit, so use this only for work that takes the newest state when it
    /// runs, and that can find nothing to do.
    static func asyncLong(_ queue: DispatchQueue, after delay: TimeInterval = 0,
                          execute work: @escaping @Sendable () -> Void) {
        if delay > 0 {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) {
                longWork.run(work, on: queue)
            }
        } else {
            longWork.run(work, on: queue)
        }
    }

    /// Runs `work` on `queue` after `delay` seconds. Urgent work goes ahead
    /// of the long work of other queues.
    static func async(_ queue: DispatchQueue, urgent: Bool, after delay: TimeInterval = 0,
                      execute work: @escaping @Sendable () -> Void) {
        let qos: DispatchQoS = urgent ? .userInteractive : .unspecified
        let flags: DispatchWorkItemFlags = urgent ? .enforceQoS : []
        if delay > 0 {
            queue.asyncAfter(deadline: .now() + delay, qos: qos, flags: flags, execute: work)
        } else {
            queue.async(qos: qos, flags: flags, execute: work)
        }
    }
}

/// Lets at most `count` work items run at a time, and keeps the others in
/// order until one ends. It never makes a thread wait.
private final class Limit: @unchecked Sendable {
    private let count: Int
    private let lock = NSLock()
    private var running = 0
    private var waiting: [(work: @Sendable () -> Void, queue: DispatchQueue)] = []

    init(count: Int) {
        self.count = count
    }

    func run(_ work: @escaping @Sendable () -> Void, on queue: DispatchQueue) {
        let starts: Bool = lock.withLock {
            guard running < count else {
                waiting.append((work, queue))
                return false
            }
            running += 1
            return true
        }
        if starts { start(work, on: queue) }
    }

    private func start(_ work: @escaping @Sendable () -> Void, on queue: DispatchQueue) {
        queue.async {
            work()
            self.end()
        }
    }

    private func end() {
        let item: (work: @Sendable () -> Void, queue: DispatchQueue)? = lock.withLock {
            guard !waiting.isEmpty else {
                running -= 1
                return nil
            }
            return waiting.removeFirst()
        }
        if let item { start(item.work, on: item.queue) }
    }
}
