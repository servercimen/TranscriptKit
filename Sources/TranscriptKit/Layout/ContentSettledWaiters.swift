import Foundation

/// The tasks that wait for a view to show its final content (see
/// `TranscriptTextView.contentSettled()`), and when to let them go: when
/// nothing is in flight in `work`, the stream has no text left to parse,
/// and the view has laid out and drawn on main.
@MainActor
final class ContentSettledWaiters {
    private let work: PendingWork
    /// The stream that the view shows, if any.
    var stream: () -> TranscriptStream? = { nil }
    /// Lays out on main what cannot wait, such as a new width. It can start
    /// work, such as image loads.
    var layOut: () -> Void = {}
    /// Draws what the last layout needs, once nothing is in flight.
    var draw: () -> Void = {}

    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var nextID = 0
    private weak var watchedStream: TranscriptStream?

    init(work: PendingWork) {
        self.work = work
    }

    /// How many tasks wait.
    var count: Int { waiters.count }

    /// Returns when the content has settled, or at once if the task is cancelled.
    func wait() async {
        guard !Task.isCancelled else { return }
        let id = nextID
        nextID += 1
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[id] = continuation
                if waiters.count == 1 { watchWork(true) }
                check()
            }
        } onCancel: { [self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.resume(id) }
            }
        }
    }

    /// Lets every waiting task go if the content has settled.
    func check() {
        guard !waiters.isEmpty, isSettled() else { return }
        let resumed = waiters
        waiters = [:]
        watchWork(false)
        resumed.values.forEach { $0.resume() }
    }

    private func resume(_ id: Int) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        if waiters.isEmpty { watchWork(false) }
        continuation.resume()
    }

    /// Checks again each time the work runs out, while a task waits.
    private func watchWork(_ watches: Bool) {
        guard watches else {
            work.setOnIdle(nil)
            return
        }
        work.setOnIdle { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.check() }
            }
        }
    }

    private func isSettled() -> Bool {
        guard work.isIdle, streamIsIdle() else { return false }
        layOut()
        // A callback of the layout, such as `onSelectionChange`, can append
        // to the stream, and an append starts no work.
        guard work.isIdle, streamIsIdle() else { return false }
        draw()
        return true
    }

    /// The stream has no text left to parse. If it has, checks again when
    /// it becomes idle.
    private func streamIsIdle() -> Bool {
        guard let stream = stream(), !stream.isIdle else { return true }
        if watchedStream !== stream {
            watchedStream = stream
            // `flush()` runs this inline, so the check must not lay out
            // or draw inside the caller's call.
            stream.whenIdle { [weak self, weak stream] in
                guard let self else { return }
                if self.watchedStream === stream { self.watchedStream = nil }
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.check() }
                }
            }
        }
        return false
    }
}
