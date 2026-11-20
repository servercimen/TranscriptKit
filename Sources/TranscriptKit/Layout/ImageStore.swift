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

    private struct FormulaKey: Hashable {
        let math: TranscriptMath
        /// The font size, to half a point.
        let size: Int
    }

    private var mathRenderer: TranscriptMathRenderer?
    private var mathGeneration = 0
    private var formulas: [FormulaKey: TranscriptMathImage] = [:]
    private var formulasRequested: Set<FormulaKey> = []

    var hasMathRenderer: Bool { lock.withLock { mathRenderer != nil } }

    /// Sets the math renderer. Formulas drawn by an earlier one are dropped,
    /// and the revision goes up so that they are laid out again.
    func setMathRenderer(_ renderer: TranscriptMathRenderer?) {
        lock.withLock {
            mathRenderer = renderer
            mathGeneration += 1
            _revision += 1
            formulas = [:]
            formulasRequested = []
        }
    }

    /// The drawn formula if it has arrived. Starts drawing it if not.
    func formula(for math: TranscriptMath, fontSize: CGFloat) -> TranscriptMathImage? {
        let key = FormulaKey(math: math, size: Int((fontSize * 2).rounded()))
        let (formula, render, generation): (TranscriptMathImage?, TranscriptMathRenderer?, Int) = lock.withLock {
            if let formula = formulas[key] { return (formula, nil, mathGeneration) }
            guard let mathRenderer, !formulasRequested.contains(key) else { return (nil, nil, mathGeneration) }
            formulasRequested.insert(key)
            return (nil, mathRenderer, mathGeneration)
        }
        if let render {
            Task.detached { [weak self] in
                let drawn = await render(math, CGFloat(key.size) / 2)?.withAlphaAsMask()
                self?.finishFormula(key, drawn, generation: generation)
            }
        }
        return formula
    }

    private func finishFormula(_ key: FormulaKey, _ formula: TranscriptMathImage?, generation: Int) {
        let handler: (@Sendable () -> Void)? = lock.withLock {
            guard generation == mathGeneration, let formula else { return nil }
            formulas[key] = formula
            _revision += 1
            return onChange
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
