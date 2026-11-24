import Foundation
import Observation
#if canImport(UIKit) && !os(watchOS)
import QuartzCore
import UIKit
#endif

/// One parsed version of a stream. `sequence` grows with every version.
struct StreamUpdate: Sendable {
    let document: TranscriptDocument
    let sequence: Int
    /// `finish()` has been called and no text appended since.
    var isFinished = false
}

/// Streamed Markdown that views read directly, without going through SwiftUI.
///
/// `append` only stores the text. Once per screen refresh, everything appended
/// since the last refresh is handed to a background queue, parsed there in
/// one go, and passed straight on to the attached views, which lay it out on
/// their own background queues. The main thread is left with installing the
/// finished layout and drawing what changed, and SwiftUI is involved only
/// when the text's height changes.
///
/// ```swift
/// @State private var stream = TranscriptStream()
///
/// var body: some View {
///     ScrollView { TranscriptText(stream: stream) }
/// }
///
/// // As chunks arrive:
/// stream.append(chunk)
/// ```
@MainActor
public final class TranscriptStream {
    /// The document as of the last parse that reached the main thread. Text
    /// appended since then is not in it yet; call `flush()` first if you
    /// need it now.
    public private(set) var document: TranscriptDocument

    /// Changed when a view of the stream that SwiftUI has not placed yet gets
    /// a new height (see `TranscriptText`).
    let unplacedHeight = UnplacedHeightSignal()

    private let worker: StreamWorker
    private var documentSequence = 0
    private var pending = ""
    private var finishPending = false
    private var jobInFlight = false

    /// - Parameters:
    ///   - markdown: text that is already complete, such as earlier
    ///     messages. It is parsed right away. Can be called from any thread.
    ///   - tags: custom tags the text may use, and how they look; see
    ///     `TranscriptTag`. Other tags show as written.
    public nonisolated init(markdown: String = "", tags: [TranscriptTag] = []) {
        var parser = MarkdownStreamParser(tags: tags)
        if !markdown.isEmpty {
            parser.append(markdown)
        }
        document = parser.document
        worker = StreamWorker(parser: parser)
    }

    /// Adds the next piece of the stream. Chunks can split anywhere, even in
    /// the middle of a Markdown marker. The text appears at the next frame.
    public func append(_ markdown: String) {
        guard !markdown.isEmpty else { return }
        pending += markdown
        scheduleFrame()
    }

    /// Marks the end of the stream, so that text held back while it could
    /// still turn into markup is shown. More text can be appended afterwards.
    public func finish() {
        finishPending = true
        scheduleFrame()
    }

    /// Parses everything appended so far now, on the calling thread's behalf,
    /// and updates `document`. Attached views get the result as usual, in
    /// the background.
    public func flush() {
        let text = pending
        let finish = finishPending
        pending = ""
        finishPending = false
        let worker = worker
        // Waits for a job already running: the queue is serial.
        let latest = worker.queue.sync {
            _ = worker.apply(text, finish: finish)
            return worker.latest
        }
        receive(latest)
    }

    private func receive(_ update: StreamUpdate) {
        guard update.sequence > documentSequence else { return }
        documentSequence = update.sequence
        document = update.document
    }

    // MARK: Sinks

    /// Calls `sink` on the parse queue with every new version, and returns
    /// the latest version so far. Registering and reading happen together,
    /// so no version is missed; one may arrive twice, so compare `sequence`.
    /// A sink that returns false is removed.
    func attachSink(_ sink: @escaping @Sendable (StreamUpdate) -> Bool) -> (id: Int, latest: StreamUpdate) {
        worker.attach(sink)
    }

    func detachSink(_ id: Int) {
        worker.detach(id)
    }

    // MARK: Frame timing

    /// Starts parsing what has been appended, unless a parse is running.
    /// When it finishes it schedules another frame if more text arrived.
    private func startJob() {
        guard !jobInFlight, !pending.isEmpty || finishPending else { return }
        let text = pending
        let finish = finishPending
        pending = ""
        finishPending = false
        jobInFlight = true
        let worker = worker
        worker.queue.async { [weak self] in
            let update = worker.apply(text, finish: finish)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.jobInFlight = false
                    if let update { self.receive(update) }
                    if !self.pending.isEmpty || self.finishPending { self.scheduleFrame() }
                }
            }
        }
    }

    #if canImport(UIKit) && !os(watchOS)
    /// Runs while there is something to hand over and is paused otherwise.
    /// `nonisolated(unsafe)` so that `deinit` can stop it.
    nonisolated(unsafe) private var displayLink: CADisplayLink?

    deinit {
        displayLink?.invalidate()
    }

    private func scheduleFrame() {
        if let displayLink {
            displayLink.isPaused = false
            return
        }
        // The display link keeps its target alive, so it targets a small
        // object that refers back to the stream weakly.
        let link = CADisplayLink(target: FrameTarget(stream: self), selector: #selector(FrameTarget.frame(_:)))
        // Streamed text gains nothing visible from more than 60 updates a
        // second, and each update costs a parse, a layout and a commit; on a
        // 120 Hz screen, scrolling still runs at the full rate.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    fileprivate func frame() {
        startJob()
        // Appending, or a parse finishing with more text waiting, unpauses it.
        displayLink?.isPaused = true
    }
    #else
    private var frameScheduled = false

    private func scheduleFrame() {
        guard !frameScheduled else { return }
        frameScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.frameScheduled = false
                self.startJob()
            }
        }
    }
    #endif
}

@Observable
final class UnplacedHeightSignal {
    var revision = 0
}

/// The parser and the attached sinks. `parser` is only touched on `queue`.
final class StreamWorker: @unchecked Sendable {
    let queue = WorkQueue.serial(label: "TranscriptKit.TranscriptStream")

    private var parser: MarkdownStreamParser
    private let lock = NSLock()
    private var latestUpdate: StreamUpdate
    private var sinks: [Int: @Sendable (StreamUpdate) -> Bool] = [:]
    private var nextSinkID = 0

    init(parser: MarkdownStreamParser) {
        self.parser = parser
        latestUpdate = StreamUpdate(document: parser.document, sequence: 0)
    }

    var latest: StreamUpdate {
        lock.withLock { latestUpdate }
    }

    /// Parses `text` and passes the new version to every sink. Runs on `queue`.
    func apply(_ text: String, finish: Bool) -> StreamUpdate? {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !text.isEmpty || finish else { return nil }
        let before = parser.document
        if !text.isEmpty { parser.append(text) }
        if finish { parser.finish() }
        let document = parser.document
        // Text that is held back changes nothing visible; finishing is still
        // news, as views may be waiting for it.
        guard document != before || finish != lock.withLock({ latestUpdate.isFinished }) else { return nil }

        let (update, targets) = lock.withLock {
            latestUpdate = StreamUpdate(document: document, sequence: latestUpdate.sequence + 1, isFinished: finish)
            return (latestUpdate, Array(sinks))
        }
        let finished = targets.filter { !$0.value(update) }.map(\.key)
        if !finished.isEmpty {
            lock.withLock { for id in finished { sinks[id] = nil } }
        }
        return update
    }

    func attach(_ sink: @escaping @Sendable (StreamUpdate) -> Bool) -> (id: Int, latest: StreamUpdate) {
        lock.withLock {
            nextSinkID += 1
            sinks[nextSinkID] = sink
            return (nextSinkID, latestUpdate)
        }
    }

    func detach(_ id: Int) {
        _ = lock.withLock { sinks.removeValue(forKey: id) }
    }
}

#if canImport(UIKit) && !os(watchOS)
@MainActor
private final class FrameTarget: NSObject {
    weak var stream: TranscriptStream?

    init(stream: TranscriptStream) {
        self.stream = stream
    }

    @objc func frame(_ link: CADisplayLink) {
        guard let stream else {
            link.invalidate()
            return
        }
        stream.frame()
    }
}
#endif
