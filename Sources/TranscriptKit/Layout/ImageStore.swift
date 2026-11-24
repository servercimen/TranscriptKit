import CoreGraphics
import Foundation

/// Loads the pictures for images in the text with the loader the app gave
/// the view, and keeps them, and the colors of code blocks from the app's
/// highlighter. Any thread.
///
/// Nothing is fetched unless the app sets a loader: an image URL written by
/// a model can carry data out of the conversation when it is fetched.
final class TranscriptImageStore: @unchecked Sendable {
    typealias Loader = @Sendable (TranscriptImage) async -> CGImage?

    /// Counts the loads, formulas and highlights in flight.
    let work: PendingWork
    private let lock = NSLock()
    private var pictures: [String: CGImage] = [:]
    private var requested: Set<String> = []
    private var loader: Loader?
    private var onChange: (@Sendable () -> Void)?
    /// Runs `onChange`: on the main queue, unless a test gives its own.
    private let deliver: @Sendable (@escaping @Sendable () -> Void) -> Void
    /// `onChange` is waiting to run, and changes until then need no call of their own.
    private var changeScheduled = false
    private var generation = 0
    private var _revision = 0

    private var highlightGeneration = 0
    /// The app's highlighter, and for each code block (by id) the colors for
    /// the last text it was asked about, which block is being highlighted,
    /// and the newest text waiting for its turn.
    private var highlighter: TranscriptCodeHighlighter?
    private var highlights: [String: (text: String, language: String?, marks: [TranscriptCodeHighlight])] = [:]
    private var highlighting: Set<String> = []
    private var waitingCode: [String: (text: String, language: String?)] = [:]

    /// Goes up each time a picture arrives; layouts made at an older
    /// revision may show placeholders where pictures now are.
    var revision: Int { lock.withLock { _revision } }

    /// - Parameters:
    ///   - mathCache: where drawn formulas are kept. A store has a cache of
    ///     its own unless it is given one that views share.
    ///   - work: counts the loads, formulas and highlights in flight, and
    ///     each change until `onChange` has run for it.
    ///   - deliver: runs `onChange`.
    ///   - settle: runs its work once the LaTeX of a formula that the
    ///     renderer could not draw may have stopped changing.
    init(mathCache: TranscriptMathCache = TranscriptMathCache(),
         work: PendingWork = PendingWork(),
         deliver: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
         settle: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = {
             DispatchQueue.global().asyncAfter(deadline: .now() + 1, execute: $0)
         }) {
        self.mathCache = mathCache
        self.work = work
        self.deliver = deliver
        self.settle = settle
        mathCache.add(self)
    }

    /// Sets the loader and what to call when a picture has arrived; see
    /// `setOnChange`. Pictures loaded with an earlier loader are dropped, and the
    /// revision goes up so that images already laid out are asked for again.
    func setLoader(_ loader: Loader?, onChange: (@Sendable () -> Void)?) {
        lock.withLock {
            self.loader = loader
            self.onChange = onChange
            generation += 1
            _revision += 1
            pictures = [:]
            requested = []
        }
    }

    /// Sets what to call on the main queue when pictures, colors or formulas
    /// arrive. Those that arrive before it runs share one call, so that the
    /// view lays out once for them. Work that the call starts must begin on
    /// `work` before it returns.
    func setOnChange(_ onChange: (@Sendable () -> Void)?) {
        lock.withLock { self.onChange = onChange }
    }

    var hasHighlighter: Bool { lock.withLock { highlighter != nil } }

    /// Sets the highlighter. Colors from an earlier one are dropped, and the
    /// revision goes up so that code blocks are laid out again.
    func setHighlighter(_ highlighter: TranscriptCodeHighlighter?) {
        lock.withLock {
            self.highlighter = highlighter
            highlightGeneration += 1
            _revision += 1
            highlights = [:]
            highlighting = []
            waitingCode = [:]
        }
    }

    /// The colors for a code block's `text`. When they are not there yet,
    /// highlighting starts (or waits for the block's current one to end), and
    /// the colors for the block's last text are given meanwhile: while text
    /// streams in, they still fit the part of it they were made for.
    func highlights(for block: String, text: String, language: String?) -> [TranscriptCodeHighlight] {
        let (marks, start): ([TranscriptCodeHighlight], (TranscriptCodeHighlighter, Int)?) = lock.withLock {
            guard let highlighter else { return ([], nil) }
            let known = highlights[block]
            if let known, known.text == text, known.language == language { return (known.marks, nil) }
            let stale = known?.marks ?? []
            if highlighting.contains(block) {
                waitingCode[block] = (text, language)
                return (stale, nil)
            }
            highlighting.insert(block)
            return (stale, (highlighter, highlightGeneration))
        }
        if let (highlighter, generation) = start {
            highlight(block, text: text, language: language, with: highlighter, generation: generation)
        }
        return marks
    }

    private func highlight(_ block: String, text: String, language: String?, with highlighter: @escaping TranscriptCodeHighlighter,
                           generation: Int) {
        let work = work
        work.begin()
        Task.detached { [weak self] in
            let marks = await highlighter(text, language)
            self?.finishHighlight(block, text: text, language: language, marks: marks, generation: generation)
            work.end()
        }
    }

    private func finishHighlight(_ block: String, text: String, language: String?, marks: [TranscriptCodeHighlight], generation: Int) {
        let (changed, next): (Bool, (TranscriptCodeHighlighter, String, String?)?) = lock.withLock {
            guard generation == highlightGeneration else { return (false, nil) }
            highlights[block] = (text, language, marks)
            _revision += 1
            if let waiting = waitingCode.removeValue(forKey: block), let highlighter, waiting.text != text || waiting.language != language {
                return (true, (highlighter, waiting.text, waiting.language))
            }
            highlighting.remove(block)
            return (true, nil)
        }
        if let (highlighter, text, language) = next {
            highlight(block, text: text, language: language, with: highlighter, generation: generation)
        }
        if changed { notifyChange() }
    }

    // MARK: Formulas

    /// Which formula of a block: the block's id, and how many formulas come
    /// before it in the block. While a formula streams in, its LaTeX changes
    /// and its slot stays the same.
    struct MathSlot: Hashable, Sendable {
        let block: String
        let index: Int
    }

    /// What to show for a formula.
    enum Formula {
        /// Its image, or while it is drawn, the last image of its slot.
        case drawn(TranscriptMathImage)
        /// It is being drawn, and its slot has no image yet.
        case pending
        /// Its LaTeX as written: there is no renderer, or it returned nil.
        case asWritten
    }

    /// A slot, as for code blocks: what it shows and what is drawn for it.
    private struct SlotState {
        /// The formula the slot was asked for last.
        var asked: TranscriptMathCache.Key?
        /// The slot's last image, and its formula. The image is kept here
        /// too, so that a formula on screen that the cache removed is not
        /// drawn again, which would remove another one.
        var shown: (key: TranscriptMathCache.Key, image: TranscriptMathImage)?
        /// The last formula that the renderer could not draw, and whether
        /// its LaTeX stayed the same long enough after that to show it.
        var failed: TranscriptMathCache.Key?
        var failureSettled = false
        /// The formula being drawn, and the newest one waiting for its turn.
        var drawing: TranscriptMathCache.Key?
        var waiting: TranscriptMathCache.Key?
        /// The slot showed a newer formula than the one being drawn, which
        /// then must not replace it.
        var drawingIsOutdated = false
    }

    private var mathRenderer: TranscriptMathRenderer?
    private var mathCache: TranscriptMathCache
    private var mathGeneration = 0
    private var mathSlots: [MathSlot: SlotState] = [:]
    /// How many slots were kept when slots of other documents were last removed.
    private var keptMathSlots = 0
    /// Runs its work once the LaTeX of a formula that failed may have
    /// stopped changing.
    private let settle: @Sendable (@escaping @Sendable () -> Void) -> Void

    var hasMathRenderer: Bool { lock.withLock { mathRenderer != nil } }

    /// Sets the math renderer. Formulas are asked for again, and the revision
    /// goes up so that they are laid out again. The cache keeps what it has,
    /// because views that share it set their renderers one by one.
    func setMathRenderer(_ renderer: TranscriptMathRenderer?) {
        lock.withLock {
            mathRenderer = renderer
            resetFormulas()
        }
    }

    /// Sets where drawn formulas are kept, and lays them out again.
    func setMathCache(_ cache: TranscriptMathCache) {
        let changed: Bool = lock.withLock {
            guard cache !== mathCache else { return false }
            mathCache = cache
            resetFormulas()
            return true
        }
        if changed { cache.add(self) }
    }

    /// The cache removed all its formulas: they are drawn again.
    func mathCacheWasEmptied(_ cache: TranscriptMathCache) {
        let changed: Bool = lock.withLock {
            guard cache === mathCache else { return false }
            resetFormulas()
            return mathRenderer != nil
        }
        if changed { notifyChange() }
    }

    private func resetFormulas() {
        mathGeneration += 1
        _revision += 1
        mathSlots = [:]
        keptMathSlots = 0
    }

    /// Removes the slots of blocks that are not in `document`, so that a
    /// view that shows one document after another does not keep all their
    /// formulas. The slots of `document` all stay, however many there are.
    func keepFormulas(of document: TranscriptDocument) {
        lock.withLock {
            guard mathSlots.count > keptMathSlots * 2 + 64 else { return }
            let blocks = Set(document.blocks.map(\.id))
            mathSlots = mathSlots.filter { blocks.contains($0.key.block) || $0.value.drawing != nil }
            keptMathSlots = mathSlots.count
        }
    }

    /// What to show for `math` in `slot`. When it is not drawn yet, drawing
    /// starts (or waits for the slot's current one to end), and the slot's
    /// last image is given meanwhile: while a formula streams in, its last
    /// image is closer to the new one than empty space is.
    ///
    /// A renderer can return nil for LaTeX that is not complete yet. Then the
    /// slot shows the same until its LaTeX stays the same for a moment, and
    /// only after that shows the LaTeX as written.
    func formula(for math: TranscriptMath, fontSize: CGFloat, in slot: MathSlot) -> Formula {
        let key = TranscriptMathCache.Key(math: math, fontSize: fontSize)
        let (formula, start): (Formula, (TranscriptMathRenderer, TranscriptMathCache, Int)?) = lock.withLock {
            guard let mathRenderer else { return (.asWritten, nil) }
            var state = mathSlots[slot] ?? SlotState()
            defer { mathSlots[slot] = state }
            state.asked = key
            if let image = mathCache.image(for: key) {
                state.shown = (key, image)
                state.waiting = nil
                state.drawingIsOutdated = state.drawing != nil
                return (.drawn(image), nil)
            }
            if let shown = state.shown, shown.key == key {
                state.waiting = nil
                state.drawingIsOutdated = state.drawing != nil
                return (.drawn(shown.image), nil)
            }
            var meanwhile = Formula.pending
            if let shown = state.shown, Self.mayBeEarlierVersion(shown.key.math, of: math) { meanwhile = .drawn(shown.image) }
            if state.failed == key {
                state.waiting = nil
                return (state.failureSettled ? .asWritten : meanwhile, nil)
            }
            if let drawing = state.drawing {
                state.waiting = drawing == key ? nil : key
                return (meanwhile, nil)
            }
            state.drawing = key
            return (meanwhile, (mathRenderer, mathCache, mathGeneration))
        }
        if let (renderer, cache, generation) = start {
            draw(key, in: slot, with: renderer, cache: cache, generation: generation)
        }
        return formula
    }

    /// Whether `earlier` can be the same formula as `later` before more of
    /// it arrived. Block ids repeat in documents parsed with the same id
    /// prefix, so a slot can hold another document's formula.
    static func mayBeEarlierVersion(_ earlier: TranscriptMath, of later: TranscriptMath) -> Bool {
        guard earlier.isDisplay == later.isDisplay else { return false }
        let shared = zip(earlier.tex, later.tex).prefix { $0 == $1 }.count
        return shared > 0 && shared * 2 >= earlier.tex.count
    }

    private func draw(_ key: TranscriptMathCache.Key, in slot: MathSlot, with renderer: @escaping TranscriptMathRenderer,
                      cache: TranscriptMathCache, generation: Int) {
        let work = work
        work.begin()
        cache.draw(key, with: renderer) { [weak self] result in
            self?.finishFormula(key, in: slot, result, generation: generation)
            work.end()
        }
    }

    private func finishFormula(_ key: TranscriptMathCache.Key, in slot: MathSlot, _ result: TranscriptMathCache.Result,
                               generation: Int) {
        let (changed, failed, next): (Bool, Bool, (TranscriptMathCache.Key, TranscriptMathRenderer, TranscriptMathCache)?) = lock.withLock {
            guard generation == mathGeneration, var state = mathSlots[slot] else { return (false, false, nil) }
            defer { mathSlots[slot] = state }
            let isNewest = key == state.asked
            var changed = false
            var failed = false
            switch result {
            case .drawn(let image):
                // An older formula's image stands in for the newest until that is drawn.
                let standsIn = !state.drawingIsOutdated && state.asked.map { Self.mayBeEarlierVersion(key.math, of: $0.math) } == true
                if isNewest || standsIn {
                    state.shown = (key, image)
                    changed = true
                }
            case .failed:
                if isNewest {
                    state.failed = key
                    state.failureSettled = false
                    failed = true
                }
            }
            if changed { _revision += 1 }
            state.drawingIsOutdated = false
            if let waiting = state.waiting, let mathRenderer {
                state.waiting = nil
                state.drawing = waiting
                return (changed, failed, (waiting, mathRenderer, mathCache))
            }
            state.waiting = nil
            state.drawing = nil
            return (changed, failed, nil)
        }
        if let (waiting, renderer, cache) = next {
            draw(waiting, in: slot, with: renderer, cache: cache, generation: generation)
        }
        if failed {
            let work = work
            work.begin()
            settle { [weak self] in
                self?.settleFailure(key, in: slot, generation: generation)
                work.end()
            }
        }
        if changed { notifyChange() }
    }

    /// How many slots the store keeps. For tests.
    var mathSlotCount: Int { lock.withLock { mathSlots.count } }

    /// Shows the LaTeX of a formula that failed, if the slot was not asked
    /// for other LaTeX since.
    private func settleFailure(_ key: TranscriptMathCache.Key, in slot: MathSlot, generation: Int) {
        let changed: Bool = lock.withLock {
            guard generation == mathGeneration, var state = mathSlots[slot], state.failed == key, state.asked == key,
                  !state.failureSettled else { return false }
            state.failureSettled = true
            mathSlots[slot] = state
            _revision += 1
            return true
        }
        if changed { notifyChange() }
    }

    /// The picture for `image` if it has arrived. Starts loading it if not.
    func picture(for image: TranscriptImage) -> CGImage? {
        let (picture, load, generation): (CGImage?, Loader?, Int) = lock.withLock {
            if let picture = pictures[image.source] { return (picture, nil, self.generation) }
            guard let loader, !requested.contains(image.source) else { return (nil, nil, self.generation) }
            requested.insert(image.source)
            return (nil, loader, self.generation)
        }
        if let load {
            let work = work
            work.begin()
            Task.detached { [weak self] in
                let box = PictureBox(picture: await load(image))
                self?.finish(image.source, box, generation: generation)
                work.end()
            }
        }
        return picture
    }

    private func finish(_ source: String, _ box: PictureBox, generation: Int) {
        let changed: Bool = lock.withLock {
            guard generation == self.generation, let picture = box.picture else { return false }
            pictures[source] = picture
            _revision += 1
            return true
        }
        if changed { notifyChange() }
    }

    /// Calls `onChange` with `deliver`, once for all the changes that come
    /// before it runs.
    private func notifyChange() {
        let schedule: Bool = lock.withLock {
            guard onChange != nil, !changeScheduled else { return false }
            changeScheduled = true
            return true
        }
        guard schedule else { return }
        let work = work
        work.begin()
        deliver { [weak self] in
            defer { work.end() }
            guard let self else { return }
            let handler = lock.withLock {
                changeScheduled = false
                return onChange
            }
            handler?()
        }
    }
}

/// CGImage is immutable, so it is safe to hand between threads.
private struct PictureBox: @unchecked Sendable {
    let picture: CGImage?
}
