import CoreGraphics
import Foundation
import QuartzCore

/// Lays out one view's documents on a background queue.
///
/// Documents come in from any thread through `submit`. Only the newest
/// waiting one is laid out (the layout reuses the previous one, so skipping
/// versions loses nothing), at most once per display frame, and results
/// collect in a mailbox that the view empties on the main thread. Results that pile up before the view gets to
/// them are merged, so the view installs at most one layout per turn of the
/// main run loop.
///
/// The main thread lays out synchronously only when it cannot wait: the
/// first layout, and a change of width or style. It does so through
/// `queue.sync`, so the engine's state is only ever touched on its queue.
///
/// While text is being appended, the engine also draws the end of the
/// document into a surface (see `TailRenderer`), which travels with the
/// layout so the view can show both in one transaction.
final class LayoutEngine: @unchecked Sendable {
    struct Request: Sendable {
        var document: TranscriptDocument
        /// Which input the document came from (a stream, or direct sets).
        /// A higher source replaces a lower one; requests from older
        /// sources are ignored.
        var source: Int
        /// Order within a source.
        var sequence: Int
    }

    struct Output: Sendable {
        let layout: DocumentLayout
        let source: Int
        /// The layout this one was computed from.
        let base: DocumentLayout?
        /// `layout`'s document only adds to `base`'s, so offsets and
        /// selection geometry from `base` are still valid.
        let isAppend: Bool
        /// With `isAppend`: everything above this y is drawn the same as in
        /// `base`, apart from `restyled`.
        let changedTop: CGFloat?
        /// With `isAppend`: blocks above `changedTop` drawn differently in
        /// place, such as a reference that became a link. Their frames.
        var restyled: [CGRect] = []
        /// The end of the document, drawn, while text is being appended.
        /// The view shows it in place of its own drawing from `tail.top` down.
        let tail: TailRenderer.Frame?
    }

    let queue = DispatchQueue(label: "TranscriptKit.layout", qos: .userInitiated)
    /// Pictures for the documents' images, if the view was given a loader.
    let images = TranscriptImageStore()

    // Guarded by `lock`.
    private let lock = NSLock()
    private var pending: Request?
    private var drainScheduled = false
    /// Layouts are made at most this often: a document that arrives sooner
    /// waits, and is replaced by any newer one that arrives meanwhile. More
    /// than one layout per display frame would never be seen.
    private var frameInterval: CFTimeInterval = 1.0 / 60
    private var lastDrain: CFTimeInterval = 0
    private var currentSource = 0
    private var lastSequence = Int.min
    private var mailbox: Output?
    private var isShutDown = false
    private var onOutput: (@Sendable () -> Void)?
    /// Main has been asked to take the mailbox and has not yet.
    private var wakeScheduled = false
    /// How to draw the tail, or nil to draw none (no window yet).
    private var tailStyle: (colors: TailRenderer.Colors, scale: CGFloat, generation: Int)?
    private var tailStyleGeneration = 0

    // Only touched on `queue`.
    private var latestDocument = TranscriptDocument()
    private var latestSource = 0
    private var base: DocumentLayout?
    /// A layout made for `sizeThatFits` at a width other than the current one.
    private var measured: DocumentLayout?
    private var width: CGFloat = 0
    private var style = TranscriptStyle()
    /// Layouts made in the background, for tests.
    private var backgroundLayouts = 0
    private var tailRenderer: TailRenderer?
    private var tailRendererGeneration = -1
    /// Text is being appended, so each output gets a drawn tail.
    private var tailActive = false

    /// Called on the engine's queue when main should take the mailbox.
    func setOutputHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { onOutput = handler }
    }

    /// Colours and display scale for drawing the tail, or nil to draw none.
    /// Any thread. A change takes effect from the next output, which starts
    /// a fresh tail.
    func setTailStyle(colors: TailRenderer.Colors?, scale: CGFloat) {
        lock.withLock {
            tailStyleGeneration += 1
            tailStyle = colors.map { ($0, scale, tailStyleGeneration) }
        }
    }

    /// Stops drawing the tail until text is appended again, for when the
    /// stream has gone quiet and the view draws everything itself.
    /// Main thread.
    func settleTail() {
        queue.sync {
            tailActive = false
            tailRenderer?.reset()
        }
    }

    /// Stops all work and lets go of the layouts, for when the view goes away.
    func shutDown() {
        lock.withLock {
            isShutDown = true
            pending = nil
            mailbox = nil
            onOutput = nil
        }
        queue.async {
            self.base = nil
            self.measured = nil
            self.latestDocument = TranscriptDocument()
        }
    }

    /// The display's refresh rate, which caps how often layouts are made.
    func setFramesPerSecond(_ framesPerSecond: Int) {
        lock.withLock { frameInterval = 1.0 / Double(max(framesPerSecond, 30)) }
    }

    /// Asks for `request` to be laid out. Any thread. Returns false once the
    /// engine has shut down, so a stream can stop sending to it.
    @discardableResult
    func submit(_ request: Request) -> Bool {
        var accepted = true
        let delay: CFTimeInterval? = lock.withLock {
            guard !isShutDown else { accepted = false; return nil }
            guard request.source >= currentSource else { return nil }
            if request.source > currentSource {
                currentSource = request.source
                lastSequence = .min
            }
            guard request.sequence > lastSequence else { return nil }
            lastSequence = request.sequence
            pending = request
            if drainScheduled { return nil }
            drainScheduled = true
            return max(lastDrain + frameInterval - CACurrentMediaTime(), 0)
        }
        if let delay {
            if delay > 0 {
                queue.asyncAfter(deadline: .now() + delay) { self.drain() }
            } else {
                queue.async { self.drain() }
            }
        }
        return accepted
    }

    private func takePending() -> Request? {
        lock.withLock { () -> Request? in
            defer { pending = nil }
            return pending
        }
    }

    /// How many layouts the background has made. For tests.
    var backgroundLayoutCount: Int { queue.sync { backgroundLayouts } }

    /// Lays out whatever is waiting now, without waiting for the next frame.
    /// For tests.
    func drainNow() {
        queue.sync { drain() }
    }

    /// Lays out the newest waiting document. One that arrives while this
    /// works schedules its own drain, a frame after this one started.
    private func drain() {
        let next: Request? = lock.withLock {
            drainScheduled = false
            guard let request = pending else { return nil }
            pending = nil
            lastDrain = CACurrentMediaTime()
            return request
        }
        guard let request = next else { return }
        latestDocument = request.document
        latestSource = request.source
        // Without a width there is nothing to lay out yet; the view lays out
        // synchronously once it has one.
        guard width > 0 else { return }
        let previous = base
        let layout = DocumentLayout(document: request.document, width: width, style: style, reusing: previous, images: images)
        base = layout
        backgroundLayouts += 1
        var isAppend = false
        var changedTop: CGFloat?
        var restyled: [CGRect] = []
        if let previous, layout.document.extends(previous.document) {
            isAppend = true
            (changedTop, restyled) = layout.changes(since: previous)
        }
        let tail = drawTail(of: layout, changedTop: changedTop, restyled: restyled)
        post(Output(layout: layout, source: request.source, base: previous, isAppend: isAppend, changedTop: changedTop,
                    restyled: restyled, tail: tail))
    }

    /// Draws `layout`'s tail if text is being appended. The first append
    /// starts the tail; it stays on for every output until settled.
    private func drawTail(of layout: DocumentLayout, changedTop: CGFloat?, restyled: [CGRect]) -> TailRenderer.Frame? {
        guard let style = lock.withLock({ tailStyle }) else {
            tailActive = false
            return nil
        }
        if tailRenderer == nil || tailRendererGeneration != style.generation {
            if let tailRenderer {
                tailRenderer.configure(colors: style.colors, scale: style.scale)
            } else {
                tailRenderer = TailRenderer(colors: style.colors, scale: style.scale)
            }
            tailRendererGeneration = style.generation
            tailActive = false
        }
        if changedTop != nil { tailActive = true }
        guard tailActive, let tailRenderer else { return nil }
        guard let frame = tailRenderer.render(layout, changedTop: changedTop, restyled: restyled) else {
            // No surface free: the view draws the tail itself until the next append.
            tailActive = false
            tailRenderer.reset()
            return nil
        }
        TranscriptDiagnostics.count(\.tailFrames)
        return frame
    }

    private func post(_ output: Output) {
        let handler: (@Sendable () -> Void)? = lock.withLock {
            guard !isShutDown else { return nil }
            if let earlier = mailbox, earlier.source == output.source {
                // Not installed yet: install the newest, measured against what is on screen.
                let top: CGFloat? = earlier.changedTop.flatMap { a in output.changedTop.map { min(a, $0) } }
                mailbox = Output(layout: output.layout, source: output.source, base: earlier.base,
                                 isAppend: earlier.isAppend && output.isAppend, changedTop: top,
                                 restyled: earlier.restyled + output.restyled, tail: output.tail)
            } else {
                mailbox = output
            }
            guard !wakeScheduled else { return nil }
            wakeScheduled = true
            return onOutput
        }
        handler?()
    }

    /// The merged result waiting to be installed, if any. Main thread.
    func takeOutput() -> Output? {
        lock.withLock { () -> Output? in
            defer {
                mailbox = nil
                wakeScheduled = false
            }
            return mailbox
        }
    }

    // MARK: Synchronous layout (main thread)

    /// Lays out the newest document at `width` now and makes it the base for
    /// what follows. Anything waiting in the mailbox is older and dropped.
    func relayout(width: CGFloat, style: TranscriptStyle) -> (layout: DocumentLayout, source: Int)? {
        queue.sync {
            if let request = takePending() {
                latestDocument = request.document
                latestSource = request.source
            }
            self.width = width
            self.style = style
            guard width > 0 else { return nil }
            let reuse = [measured, base].compactMap { $0 }.first { $0.width == width && $0.style == style } ?? base
            let layout = DocumentLayout(document: latestDocument, width: width, style: style, reusing: reuse, images: images)
            base = layout
            measured = nil
            // The view draws everything itself after this; the tail starts
            // again with the next append.
            tailActive = false
            tailRenderer?.reset()
            lock.withLock { mailbox = nil }
            return (layout, latestSource)
        }
    }

    /// The height of the newest document at `width`, for sizing. The layout
    /// is kept, so laying out at that width afterwards costs nothing.
    func measure(width: CGFloat, style: TranscriptStyle) -> CGFloat {
        queue.sync {
            // A waiting request stays waiting: the drain still lays it out at the current width.
            let document = lock.withLock { pending?.document } ?? latestDocument
            let reuse = [measured, base].compactMap { $0 }.first { $0.width == width && $0.style == style }
            let layout = DocumentLayout(document: document, width: width, style: style, reusing: reuse, images: images)
            measured = layout
            return layout.height
        }
    }
}
