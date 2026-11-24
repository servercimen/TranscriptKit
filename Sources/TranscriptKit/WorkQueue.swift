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
