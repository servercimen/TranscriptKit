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

    private let lock = NSLock()
    private var pictures: [String: CGImage] = [:]
    private var requested: Set<String> = []
    private var loader: Loader?
    private var onChange: (@Sendable () -> Void)?
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

    /// Sets the loader and what to call (on any thread) when a picture has
    /// arrived. Pictures loaded with an earlier loader are dropped, and the
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

    /// Sets what to call (on any thread) when a picture or colors arrive.
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
        Task.detached { [weak self] in
            let marks = await highlighter(text, language)
            self?.finishHighlight(block, text: text, language: language, marks: marks, generation: generation)
        }
    }

    private func finishHighlight(_ block: String, text: String, language: String?, marks: [TranscriptCodeHighlight], generation: Int) {
        let (handler, next): ((@Sendable () -> Void)?, (TranscriptCodeHighlighter, String, String?)?) = lock.withLock {
            guard generation == highlightGeneration else { return (nil, nil) }
            highlights[block] = (text, language, marks)
            _revision += 1
            if let waiting = waitingCode.removeValue(forKey: block), let highlighter, waiting.text != text || waiting.language != language {
                return (onChange, (highlighter, waiting.text, waiting.language))
            }
            highlighting.remove(block)
            return (onChange, nil)
        }
        if let (highlighter, text, language) = next {
            highlight(block, text: text, language: language, with: highlighter, generation: generation)
        }
        handler?()
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

    private var mathRenderer: TranscriptMathRenderer?
    private var mathCache: TranscriptMathCache
    private var mathGeneration = 0
    /// For each slot, as for code blocks: the formula it last showed drawn,
    /// the one being drawn, and the newest one waiting for its turn.
    private var shownFormulas: [MathSlot: TranscriptMathCache.Key] = [:]
    private var drawingFormulas: [MathSlot: TranscriptMathCache.Key] = [:]
    private var waitingFormulas: [MathSlot: TranscriptMathCache.Key] = [:]

    /// - Parameter mathCache: where drawn formulas are kept. A store has a
    ///   cache of its own unless it is given one that views share.
    init(mathCache: TranscriptMathCache = TranscriptMathCache()) {
        self.mathCache = mathCache
    }

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
        lock.withLock {
            guard cache !== mathCache else { return }
            mathCache = cache
            resetFormulas()
        }
    }

    private func resetFormulas() {
        mathGeneration += 1
        _revision += 1
        shownFormulas = [:]
        drawingFormulas = [:]
        waitingFormulas = [:]
    }

    /// What to show for `math` in `slot`. When it is not drawn yet, drawing
    /// starts (or waits for the slot's current one to end), and the slot's
    /// last image is given meanwhile: while a formula streams in, its last
    /// image is closer to the new one than empty space is.
    func formula(for math: TranscriptMath, fontSize: CGFloat, in slot: MathSlot) -> Formula {
        let key = TranscriptMathCache.Key(math: math, fontSize: fontSize)
        let (formula, start): (Formula, (TranscriptMathRenderer, TranscriptMathCache, Int)?) = lock.withLock {
            guard let mathRenderer else { return (.asWritten, nil) }
            switch mathCache.result(for: key) {
            case .drawn(let image)?:
                shownFormulas[slot] = key
                return (.drawn(image), nil)
            case .failed?:
                return (.asWritten, nil)
            case nil:
                break
            }
            var meanwhile = Formula.pending
            if let shown = shownFormulas[slot], Self.mayBeEarlierVersion(shown.math, of: math),
               case .drawn(let image)? = mathCache.result(for: shown) {
                meanwhile = .drawn(image)
            }
            if let drawing = drawingFormulas[slot] {
                waitingFormulas[slot] = drawing == key ? nil : key
                return (meanwhile, nil)
            }
            drawingFormulas[slot] = key
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
        cache.draw(key, with: renderer) { [weak self] result in
            self?.finishFormula(key, in: slot, result, generation: generation)
        }
    }

    private func finishFormula(_ key: TranscriptMathCache.Key, in slot: MathSlot, _ result: TranscriptMathCache.Result,
                               generation: Int) {
        let (handler, next): ((@Sendable () -> Void)?, (TranscriptMathCache.Key, TranscriptMathRenderer, TranscriptMathCache)?) = lock.withLock {
            guard generation == mathGeneration else { return (nil, nil) }
            if case .drawn = result { shownFormulas[slot] = key }
            _revision += 1
            if let waiting = waitingFormulas.removeValue(forKey: slot), waiting != key, let mathRenderer {
                drawingFormulas[slot] = waiting
                return (onChange, (waiting, mathRenderer, mathCache))
            }
            drawingFormulas[slot] = nil
            return (onChange, nil)
        }
        if let (waiting, renderer, cache) = next {
            draw(waiting, in: slot, with: renderer, cache: cache, generation: generation)
        }
        handler?()
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
            Task.detached { [weak self] in
                let box = PictureBox(picture: await load(image))
                self?.finish(image.source, box, generation: generation)
            }
        }
        return picture
    }

    private func finish(_ source: String, _ box: PictureBox, generation: Int) {
        let handler: (@Sendable () -> Void)? = lock.withLock {
            guard generation == self.generation, let picture = box.picture else { return nil }
            pictures[source] = picture
            _revision += 1
            return onChange
        }
        handler?()
    }
}

/// CGImage is immutable, so it is safe to hand between threads.
private struct PictureBox: @unchecked Sendable {
    let picture: CGImage?
}
