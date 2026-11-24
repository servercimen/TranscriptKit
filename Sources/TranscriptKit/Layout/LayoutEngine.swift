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
/// first layout, a change of width or style, and a replaced document when
/// the view's `replacementCrossfadeDuration` asks for it. It does so through
/// `queue.sync`, so the engine's state is only ever touched on its queue.
/// When the queue is idle, the main thread does that work itself and does
/// not wait for a thread. The queue shares its threads with the queues of
/// all other views and streams (see `WorkQueue`). A drain of short work,
/// such as text added to the end, goes ahead of the long layouts of other
/// views. A long drain waits for its turn among the long layouts of all
/// views; a `sync` call does not wait for that turn.
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
        /// No more text is coming: the stream has finished, or the document
        /// was set directly.
        var isFinished = false
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
        /// Animated tags that closed in this update and play right away:
        /// the view plays their animations from now on. Their rows are in
        /// `restyled`.
        var started: [TagKey] = []
        /// Animated tags that closed in this update and wait for the view to
        /// start them; they are drawn without their shapes until then.
        var waiting: [TagKey] = []
        /// How `tail` was drawn: which tags it left out, and how far.
        var hidden: TagHiding = .none
        /// The text that is fading in, from `hidden.fadingFrom` on, which
        /// `tail` leaves out.
        var fade: FadeFrame?
        /// The request's `isFinished`.
        var isFinished = false
        /// How far blocks were scrolled sideways when `tail` and `fade` were drawn.
        var scroll: SideScroll = .none

        /// `later`, measured against what `earlier` was measured against:
        /// for installing `later` when `earlier` was never installed.
        static func merging(_ earlier: Output, _ later: Output) -> Output {
            let top: CGFloat? = earlier.changedTop.flatMap { a in later.changedTop.map { min(a, $0) } }
            return Output(layout: later.layout, source: later.source, base: earlier.base,
                          isAppend: earlier.isAppend && later.isAppend, changedTop: top,
                          restyled: earlier.restyled + later.restyled, tail: later.tail,
                          started: earlier.started + later.started, waiting: earlier.waiting + later.waiting,
                          hidden: later.hidden, fade: later.fade, isFinished: later.isFinished, scroll: later.scroll)
        }
    }

    let queue = WorkQueue.serial(label: "TranscriptKit.layout")
    /// The work in flight: drains that are scheduled or running, a result
    /// that the view has not taken yet, and the image store's loads.
    let work: PendingWork
    /// Pictures for the documents' images, if the view was given a loader.
    /// Formulas are kept in the cache that views share.
    let images: TranscriptImageStore

    init() {
        work = PendingWork()
        images = TranscriptImageStore(mathCache: .shared, work: work)
    }

    // Guarded by `lock`.
    private let lock = NSLock()
    private var pending: Request?
    /// `pending` waits for `relayout` on the main thread: a drain leaves it.
    private var pendingIsForMain = false
    private var drainScheduled = false
    /// The scheduled drain goes ahead of the long work of other views.
    private var drainIsUrgent = false
    /// Identifies the scheduled drain. An older drain that runs later, as a
    /// long drain can, leaves the schedule alone.
    private var drainID = 0
    /// The document of the newest layout, or of the one the queue makes
    /// next. A document that only adds a little to it is short work.
    private var laidOut = TranscriptDocument()
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
    /// Whether tags that close start their animations.
    private var animationsEnabled = false
    /// Whether they start as soon as they close, or wait for the view.
    private var startsImmediately = true
    /// Tags whose animations play, or wait to, and text that fades in: the
    /// tail is drawn without them.
    private var hiding = TagHiding()
    /// How long appended text takes to fade in, or nil for no fade.
    private var fadeDuration: CFTimeInterval?
    /// How far blocks are scrolled sideways in the view: the tail and the
    /// fading text are drawn with it.
    private var sideScroll = SideScroll()
    /// Appended text from `hiding.fadingFrom` on, oldest first: still fading
    /// in, or done but on the line the oldest still fades on.
    private var fades: [Fade] = []
    private var lastFadeID = 0
    /// The fades' clock. Tests set their own.
    var clock: @Sendable () -> CFTimeInterval = { CACurrentMediaTime() }

    // Only touched on `queue`.
    private var latestDocument = TranscriptDocument()
    private var latestSource = 0
    private var latestFinished = false
    private var base: DocumentLayout?
    /// A layout made for `sizeThatFits` at a width other than the current one.
    private var measured: DocumentLayout?
    private var width: CGFloat = 0
    private var style = TranscriptStyle()
    /// Layouts made in the background, for tests.
    private var backgroundLayouts = 0
    private var tailRenderer: TailRenderer?
    private let fadeRenderer = FadeRenderer()
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

    /// Whether animated tags that close from now on start their
    /// animations, and whether they start as soon as they close or wait
    /// until the view starts them. Any thread.
    func setAnimationsEnabled(_ enabled: Bool, immediately: Bool = true) {
        lock.withLock {
            animationsEnabled = enabled
            startsImmediately = immediately
        }
    }

    /// How long text appended from now on takes to fade in, or nil for no
    /// fade. Any thread.
    func setFadeDuration(_ duration: CFTimeInterval?) {
        lock.withLock { fadeDuration = duration.flatMap { $0 > 0 ? $0 : nil } }
    }

    /// How far blocks are scrolled sideways, for the tails and fades drawn
    /// from now on. Any thread.
    func setSideScroll(_ scroll: SideScroll) {
        lock.withLock { sideScroll = scroll }
    }

    /// Ends every fade, for when the view draws the text at rest. Returns
    /// where the fading text started, if any did. Any thread.
    func endFades() -> Int? {
        lock.withLock {
            let from = hiding.fadingFrom
            fades.removeAll()
            hiding.fadingFrom = nil
            return from
        }
    }

    /// The view holds these closed tags back until their timing lets them
    /// play, as tags that close in an update wait: tails leave their shapes
    /// out. Any thread.
    func holdAnimations(_ keys: some Sequence<TagKey>) {
        lock.withLock { hiding.waiting.formUnion(keys) }
    }

    /// The view has started these waiting tags' animations: tails leave
    /// them out entirely. Any thread.
    func playAnimations(_ keys: some Sequence<TagKey>) {
        lock.withLock {
            for key in keys where hiding.waiting.remove(key) != nil { hiding.playing.insert(key) }
        }
    }

    /// The view has stopped playing these tags' animations, or stopped
    /// waiting to: tails are drawn with them again. Any thread.
    func settleAnimations(_ keys: some Sequence<TagKey>) {
        lock.withLock {
            for key in keys {
                hiding.playing.remove(key)
                hiding.waiting.remove(key)
            }
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
            pendingIsForMain = false
            mailbox = nil
            onOutput = nil
            laidOut = TranscriptDocument()
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
    ///
    /// - Parameter schedulesLayout: false when the caller calls `relayout`
    ///   at once, which lays out the request on the main thread. The queue
    ///   then does not lay it out first, also when a drain is already
    ///   scheduled.
    @discardableResult
    func submit(_ request: Request, schedulesLayout: Bool = true) -> Bool {
        var accepted = true
        let urgent = Self.isShortWork(request.document, after: lock.withLock { laidOut })
        let schedule: (delay: CFTimeInterval, urgent: Bool, id: Int)? = lock.withLock {
            guard !isShutDown else { accepted = false; return nil }
            guard request.source >= currentSource else { return nil }
            if request.source > currentSource {
                currentSource = request.source
                lastSequence = .min
            }
            guard request.sequence > lastSequence else { return nil }
            lastSequence = request.sequence
            pending = request
            pendingIsForMain = !schedulesLayout
            if !schedulesLayout { return nil }
            // A drain that is not urgent can wait behind the work of other
            // views, so short work schedules an urgent one of its own. The
            // drain that runs first takes the request.
            if drainScheduled, drainIsUrgent || !urgent { return nil }
            drainScheduled = true
            drainIsUrgent = urgent
            drainID += 1
            return (max(lastDrain + frameInterval - CACurrentMediaTime(), 0), urgent, drainID)
        }
        if let schedule {
            let id = schedule.id
            work.begin()
            if schedule.urgent {
                WorkQueue.async(queue, urgent: true, after: schedule.delay) { self.drain(id); self.work.end() }
            } else {
                WorkQueue.asyncLong(queue, after: schedule.delay) { self.drain(id); self.work.end() }
            }
        }
        return accepted
    }

    /// Whether laying out `document` takes about a millisecond or less: its
    /// text is short, or it adds only a little text to the end of `laidOut`,
    /// whose layout it reuses. An urgent drain keeps its QoS when a longer
    /// document replaces the waiting one.
    private static func isShortWork(_ document: TranscriptDocument, after laidOut: TranscriptDocument) -> Bool {
        let length = document.utf16Count
        if length <= WorkQueue.shortLength { return true }
        // Documents that share no storage, as when the app parses each
        // version itself, would compare every block. A stream shares all
        // but its last block or two.
        guard laidOut.count > 0, length - laidOut.utf16Count <= WorkQueue.shortLength,
              laidOut.count - document.knownSharedPrefix(with: laidOut) <= 8 else { return false }
        return document.extends(laidOut)
    }

    private func takePending() -> Request? {
        lock.withLock { () -> Request? in
            defer {
                pending = nil
                pendingIsForMain = false
            }
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
    ///
    /// - Parameter id: the drain's `drainID`, or nil to end the schedule.
    private func drain(_ id: Int? = nil) {
        let next: Request? = lock.withLock {
            if id == nil || id == drainID {
                drainScheduled = false
                drainIsUrgent = false
            }
            guard let request = pending, !pendingIsForMain else { return nil }
            pending = nil
            lastDrain = CACurrentMediaTime()
            if width > 0 { laidOut = request.document }
            return request
        }
        guard let request = next else { return }
        latestDocument = request.document
        latestSource = request.source
        latestFinished = request.isFinished
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
        var started: [TagKey] = []
        var waiting: [TagKey] = []
        if let previous, layout.document.extends(previous.document) {
            isAppend = true
            (changedTop, restyled) = layout.changes(since: previous)
            // Tags that closed in this update start their animations, from
            // now on leaving the tag to the view, or wait for the view to
            // start them, without their shapes until then.
            let (enabled, immediately) = lock.withLock { (animationsEnabled, startsImmediately) }
            if enabled {
                for key in layout.newlyClosedAnimatedTags(since: previous) {
                    guard let tag = layout.animatedTag(key) else { continue }
                    if immediately {
                        started.append(key)
                        restyled.append(CGRect(x: 0, y: tag.band.lowerBound, width: layout.width,
                                               height: tag.band.upperBound - tag.band.lowerBound))
                    } else {
                        waiting.append(key)
                    }
                }
                if !started.isEmpty || !waiting.isEmpty {
                    lock.withLock {
                        hiding.playing.formUnion(started)
                        hiding.waiting.formUnion(waiting)
                    }
                }
            }
        }
        let (fading, moved) = updateFades(layout: layout, appendedTo: isAppend ? previous : nil, tagsStarted: !started.isEmpty)
        if let moved { restyled.append(insideTail(moved)) }
        let (hidden, scroll) = lock.withLock { (hiding, sideScroll) }
        let tail = drawTail(of: layout, changedTop: changedTop, restyled: restyled, hiding: hidden, scroll: scroll)
        var fade: FadeFrame?
        if !fading.isEmpty, let from = hidden.fadingFrom, let style = lock.withLock({ tailStyle }) {
            fade = fadeRenderer.render(layout, from: from, fades: fading, colors: style.colors, scale: style.scale, playing: hidden.playing,
                                       scroll: scroll)
            TranscriptDiagnostics.count(\.fadeFrames)
        }
        post(Output(layout: layout, source: request.source, base: previous, isAppend: isAppend, changedTop: changedTop,
                    restyled: restyled, tail: tail, started: started, waiting: waiting, hidden: hidden, fade: fade,
                    isFinished: request.isFinished, scroll: scroll))
    }

    /// Starts a fade for the text that `layout` appends to `previous`, and
    /// moves the frontier to the start of the line that the oldest fade still
    /// in progress is on: a line is drawn again once, when all of its text is
    /// done, not once for each fade. The fades done before then stay, at
    /// full opacity. A tag that starts its animation ends them all, and its
    /// update does not fade: the animation draws the tag's letters, which a
    /// fade would draw too.
    ///
    /// - Returns: the fades in flight, and the rows to draw again because
    ///   text there stopped fading.
    private func updateFades(layout: DocumentLayout, appendedTo previous: DocumentLayout?,
                             tagsStarted: Bool) -> (fades: [Fade], moved: (rect: CGRect, lineTop: CGFloat)?) {
        let now = clock()
        let (old, new, fading): (Int?, Int?, [Fade]) = lock.withLock {
            let old = hiding.fadingFrom
            var new: Int?
            if let duration = fadeDuration, tailStyle != nil, let previous {
                if tagsStarted {
                    fades.removeAll()
                } else if layout.length > previous.length {
                    lastFadeID += 1
                    fades.append(Fade(id: lastFadeID, range: previous.length..<layout.length, start: now))
                }
                if let oldest = fades.first(where: { $0.start + duration > now })?.range.lowerBound {
                    let lineStart = layout.lines(from: oldest).first.map { $0.entry.start + $0.line.range.lowerBound } ?? oldest
                    new = old.map { max($0, min(lineStart, oldest)) } ?? oldest
                }
            }
            if let new {
                fades.removeAll { $0.range.upperBound <= new }
            } else {
                fades.removeAll()
            }
            hiding.fadingFrom = new
            return (old, new, fades)
        }
        guard let old, old != new, old < layout.length else { return (fading, nil) }
        // The lines of the text that stopped fading. In a table they are not
        // in order of y.
        let end = new ?? layout.length
        var band: CGRect?
        var margin: CGFloat = 0
        for (entry, line) in layout.lines(from: old) where entry.start + line.range.lowerBound < end {
            let frame = line.frame.offsetBy(dx: 0, dy: entry.y)
            band = band.map { $0.union(frame) } ?? frame
            margin = max(margin, FadeRenderer.margin(of: line).y)
        }
        guard let band else { return (fading, nil) }
        return (fading, (CGRect(x: 0, y: band.minY - margin, width: layout.width, height: band.height + 2 * margin), band.minY))
    }

    /// The rows to draw again for text that stopped fading. When its lines
    /// are in the tail, the band starts no higher than the tail, so the tail
    /// alone draws it, off the main thread; the tiles do not redraw glyphs
    /// that reach above their line either when text is appended.
    private func insideTail(_ moved: (rect: CGRect, lineTop: CGFloat)) -> CGRect {
        guard tailActive, let top = tailRenderer?.top, moved.lineTop >= top, moved.rect.minY < top else { return moved.rect }
        return CGRect(x: moved.rect.minX, y: top, width: moved.rect.width, height: moved.rect.maxY - top)
    }

    /// Ends the fades whose time is up and draws their rows again, as an
    /// update that adds no text, for when updates have stopped. The tail
    /// stays in use. Any thread; the result comes like any other.
    func settleFinishedFades() {
        work.begin()
        WorkQueue.async(queue, urgent: true) { [self] in
            defer { work.end() }
            guard let layout = base, width > 0, layout.width == width else { return }
            let (fading, band) = updateFades(layout: layout, appendedTo: layout, tagsStarted: false)
            guard let band else { return }
            let moved = insideTail(band)
            let (hidden, scroll) = lock.withLock { (hiding, sideScroll) }
            let tail = tailActive ? drawTail(of: layout, changedTop: layout.height, restyled: [moved], hiding: hidden, scroll: scroll) : nil
            var fade: FadeFrame?
            if !fading.isEmpty, let from = hidden.fadingFrom, let style = lock.withLock({ tailStyle }) {
                fade = fadeRenderer.render(layout, from: from, fades: fading, colors: style.colors, scale: style.scale, playing: hidden.playing,
                                           scroll: scroll)
                TranscriptDiagnostics.count(\.fadeFrames)
            }
            post(Output(layout: layout, source: latestSource, base: layout, isAppend: true, changedTop: layout.height,
                        restyled: [moved], tail: tail, hidden: hidden, fade: fade, isFinished: latestFinished, scroll: scroll))
        }
    }

    /// Draws `layout`'s tail if text is being appended. The first append
    /// starts the tail; it stays on for every output until settled.
    private func drawTail(of layout: DocumentLayout, changedTop: CGFloat?, restyled: [CGRect], hiding: TagHiding,
                          scroll: SideScroll) -> TailRenderer.Frame? {
        let fadingTop = hiding.fadingFrom.flatMap { layout.lines(from: $0).first }.map { $0.entry.y + $0.line.inkTop }
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
        guard let frame = tailRenderer.render(layout, changedTop: changedTop, restyled: restyled, hiding: hiding, fadingTop: fadingTop,
                                              scroll: scroll) else {
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
            // Not installed yet: install the newest, measured against what is
            // on screen. Also across sources when the newest builds on it, as
            // a finished stream replaced by its document does: the view never
            // saw the stream's last layout, and still gets an append.
            if let earlier = mailbox, earlier.source == output.source || output.base === earlier.layout {
                mailbox = Output.merging(earlier, output)
            } else {
                mailbox = output
            }
            guard !wakeScheduled else { return nil }
            wakeScheduled = true
            work.begin()
            return onOutput
        }
        handler?()
    }

    /// The merged result waiting to be installed, if any. Main thread.
    func takeOutput() -> Output? {
        let (output, woke): (Output?, Bool) = lock.withLock {
            defer {
                mailbox = nil
                wakeScheduled = false
            }
            return (mailbox, wakeScheduled)
        }
        // The caller installs the output before main can see the work idle.
        if woke { work.end() }
        return output
    }

    // MARK: Synchronous layout (main thread)

    /// Lays out the newest document at `width` now and makes it the base for
    /// what follows. Anything waiting in the mailbox is older and dropped.
    ///
    /// - Parameter keepingFades: text that fades in goes on fading if it is
    ///   where it was, as after the image store changed; the result says
    ///   where it starts. Otherwise the fades end.
    func relayout(width: CGFloat, style: TranscriptStyle, keepingFades: Bool = false)
        -> (layout: DocumentLayout, source: Int, isFinished: Bool, fadingFrom: Int?)? {
        queue.sync {
            if let request = takePending() {
                latestDocument = request.document
                latestSource = request.source
                latestFinished = request.isFinished
            }
            let previous = base
            let sameGeometry = width == self.width && style == self.style
            self.width = width
            self.style = style
            guard width > 0 else { return nil }
            let reuse = [measured, base].compactMap { $0 }.first { $0.width == width && $0.style == style } ?? base
            let layout = DocumentLayout(document: latestDocument, width: width, style: style, reusing: reuse, images: images)
            base = layout
            measured = nil
            // The view draws everything itself after this; the tail starts
            // again with the next append. The view tells the engine again
            // which tags still wait or play (`holdAnimations`,
            // `playAnimations`).
            tailActive = false
            tailRenderer?.reset()
            var kept: Int?
            if keepingFades, sameGeometry, let previous, let from = lock.withLock({ hiding.fadingFrom }),
               from <= previous.length, layout.document.extends(previous.document),
               layout.caretRect(at: from) == previous.caretRect(at: from),
               layout.caretRect(at: previous.length) == previous.caretRect(at: previous.length) {
                kept = from
            }
            lock.withLock {
                mailbox = nil
                laidOut = latestDocument
                hiding = TagHiding(fadingFrom: kept)
                if kept == nil { fades.removeAll() }
            }
            return (layout, latestSource, latestFinished, kept)
        }
    }

    /// Lays out the documents that arrive from now on at `width`, while the
    /// view has no width of its own: SwiftUI measured it but has not placed
    /// it, as a lazy stack does with a row of zero height. The width the view
    /// gets when it is placed replaces this one. A new style at the same
    /// width replaces the old one.
    func layOutUntilPlaced(width: CGFloat, style: TranscriptStyle) {
        guard width > 0 else { return }
        queue.async {
            let restyled = self.width == width && self.style != style
            guard self.width == 0 || restyled else { return }
            self.width = width
            self.style = style
            if let measured = self.measured, measured.width == width, measured.style == style {
                self.base = measured
            } else if restyled {
                self.base = nil
            }
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
