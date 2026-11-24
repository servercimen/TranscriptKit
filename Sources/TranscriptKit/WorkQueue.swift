import Foundation

/// The queues that parse and lay out text in the background.
///
/// Each stream and each view has its own serial queue, so its work runs in
/// order. A serial queue without a target gets a new thread when it has
/// work, however many other queues are busy, so a screen that replaces many
/// documents at once can hold one thread for each. These queues target the
/// global queue instead, and share the pool that GCD keeps at about one
/// thread for each processor core. One view's long layout uses one thread
/// of the pool; the other views go on with the rest.
///
/// The target is the global queue itself, not a concurrent queue of our
/// own: when the main thread calls `sync` on a queue with work waiting for a
/// thread of a busy pool, GCD gives that work a thread at once only when the
/// queue targets the global queue directly. Through a queue of our own, the
/// main thread waits until the pool is free.
///
/// Work on these queues must not wait for work on another of them, as
/// `sync` does: a thread that waits does no work, and GCD then starts more
/// threads.
enum WorkQueue {
    /// A serial queue for one stream or view, on the shared pool.
    static func serial(label: String) -> DispatchQueue {
        DispatchQueue(label: label, qos: .userInitiated, target: .global(qos: .userInitiated))
    }
}
