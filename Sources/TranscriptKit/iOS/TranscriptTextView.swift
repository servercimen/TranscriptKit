#if canImport(UIKit) && !os(watchOS)
import os
import UIKit

/// Why tags animate or not, at the debug level: shown in Xcode's console and
/// in Console with debug messages on, and not stored otherwise.
private let animationLog = Logger(subsystem: "TranscriptKit", category: "TagAnimations")
/// Each tag animation as an interval in Instruments' Points of Interest.
private let animationSignposter = OSSignposter(subsystem: "TranscriptKit", category: .pointsOfInterest)

/// A read-only text view that draws a whole transcript with Core Text and
/// exposes it to the system as one selectable document.
///
/// Selection handles, the loupe and the edit menu come from `UITextInteraction`;
/// this view only answers geometry and text queries through `UITextInput`.
///
/// Layout happens on a background queue. The view keeps showing, and
/// answering selection queries from, the last layout it installed until the
/// next one is ready, so text positions always match what is on screen.
///
/// Text is drawn into tiles on the main thread, except while it is being
/// appended: the end of the document is then drawn on the layout queue into
/// a surface that the view shows in place of its tiles' drawing (see
/// `TailRenderer`), installed in the same transaction as the layout. A
/// second after the last update, the tiles take that part back and the
/// surfaces are freed.
public final class TranscriptTextView: UIView, UITextInput, UIGestureRecognizerDelegate {
    /// Called when a link is tapped. By default the URL is opened by the system.
    public var openLink: (URL) -> Void = { UIApplication.shared.open($0) }

    /// Whether the text can be selected. On by default. Off, the view has no
    /// selection gestures or edit menu, and a touch that is not on a link goes
    /// to the views behind it, for example a card that reacts to taps. Links
    /// still open.
    public var isSelectable = true {
        didSet {
            guard isSelectable != oldValue else { return }
            if isSelectable {
                addInteraction(textInteraction)
            } else {
                select(nil)
                removeInteraction(textInteraction)
                if isFirstResponder { resignFirstResponder() }
            }
        }
    }

    /// The text to show. Setting it while a `stream` is attached detaches the stream.
    public var document: TranscriptDocument {
        get { stream?.document ?? directDocument }
        set {
            let replacesStream = stream != nil
            guard replacesStream || newValue != directDocument else { return }
            directDocument = newValue
            directSequence += 1
            if replacesStream {
                // Detaching submits `directDocument`, now the new one. Only
                // one document goes to the engine: an earlier one in between
                // would make the new one look like a replacement rather than
                // what the stream's text grew into.
                stream = nil
            } else {
                engine.submit(.init(document: newValue, source: source, sequence: directSequence, isFinished: true))
            }
            layOutNowIfNothingIsShown()
        }
    }

    /// A stream to show. The view then takes each update from the stream
    /// directly, in the background, without the app or SwiftUI setting `document`.
    public var stream: TranscriptStream? {
        didSet {
            guard stream !== oldValue else { return }
            if let oldValue, let sinkID { oldValue.detachSink(sinkID) }
            sinkID = nil
            source += 1
            guard let stream else {
                engine.submit(.init(document: directDocument, source: source, sequence: directSequence, isFinished: true))
                return
            }
            let engine = engine
            let source = source
            let attachment = stream.attachSink { update in
                engine.submit(.init(document: update.document, source: source, sequence: update.sequence, isFinished: update.isFinished))
            }
            sinkID = attachment.id
            engine.submit(.init(document: attachment.latest.document, source: source, sequence: attachment.latest.sequence,
                                isFinished: attachment.latest.isFinished))
            layOutNowIfNothingIsShown()
        }
    }

    public var style = TranscriptStyle() {
        didSet {
            guard style != oldValue else { return }
            relayoutNow()
        }
    }

    /// Whether custom tags with an animation play it when they finish
    /// arriving (see `TranscriptAnimationRecipe`). Off, or with Reduce
    /// Motion on, they just appear as they end up.
    public var animatesTags = true {
        didSet {
            guard animatesTags != oldValue else { return }
            updateAnimationsEnabled()
        }
    }

    /// When a tag's animation plays once its closing tag has arrived: right
    /// away (the default), or once it is on screen, once the stream has
    /// finished, or once the app calls `playTagAnimations()`, in any
    /// combination. See `TranscriptAnimationTiming`.
    public var tagAnimationTiming: TranscriptAnimationTiming = .immediately {
        didSet {
            guard tagAnimationTiming != oldValue else { return }
            updateAnimationsEnabled()
            startWaitingTagsSoon()
        }
    }

    /// Lets every tag waiting to animate now play, as soon as the rest of
    /// `tagAnimationTiming` allows. Tags that close later wait for the next
    /// call. Does nothing unless the timing includes `.whenRequested`.
    public func playTagAnimations() {
        requested.formUnion(waiting)
        startWaitingTagsSoon()
    }

    /// Loads the picture for an image in the text, called off the main thread
    /// the first time each image source is laid out. Return nil to keep
    /// showing the image's alt text.
    ///
    /// Not set by default, so no image is ever fetched: an image URL written
    /// by a model can carry data out of the conversation in its address.
    /// Fetch only from sources you trust.
    public var imageLoader: (@Sendable (TranscriptImage) async -> CGImage?)? {
        didSet {
            engine.images.setLoader(imageLoader) { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.relayoutNow() }
                }
            }
            relayoutNow()
        }
    }

    private let engine = LayoutEngine()

    /// Holds the tiles, and the tail layer above them, below the system's
    /// selection views.
    private let canvas = UIView()
    /// Shows the end of the document while text is being appended: a
    /// surface the layout queue drew (see `TailRenderer`). The tiles draw
    /// only above its top.
    private let tailLayer = CALayer()
    /// Tiles draw only above this y; the tail layer shows the rest.
    private var tailTop: CGFloat = .greatestFiniteMagnitude
    /// When a tail was last shown; one second later, if nothing newer came,
    /// the tiles take it back.
    private var lastTailShown: CFTimeInterval = 0
    private var settleCheckScheduled = false
    /// Increased whenever the view switches between a stream and direct documents.
    private var source = 0
    private var sinkID: Int?
    private var directDocument = TranscriptDocument()
    private var directSequence = 0

    /// What is on screen. Drawing, hit testing and every `UITextInput`
    /// answer come from this layout and its document.
    private var installed: DocumentLayout?
    private lazy var emptyLayout = DocumentLayout(document: TranscriptDocument(), width: 1, style: style)
    private var currentLayout: DocumentLayout { installed ?? emptyLayout }
    /// The document on screen, which can be a little behind `document`.
    private var shownDocument: TranscriptDocument { currentLayout.document }

    private var selection: Range<Int>? {
        didSet {
            let range = selectedRange
            guard range != reportedSelection else { return }
            reportedSelection = range
            onSelectionChange?(range)
        }
    }
    private var reportedSelection: Range<Int>?

    /// The selected range of the document's flat UTF-16 offset space, or nil
    /// when nothing is selected. `document.text(in:)` gives its text.
    public var selectedRange: Range<Int>? {
        guard let selection, !selection.isEmpty else { return nil }
        return selection
    }

    /// Called on the main thread after the selection changes, with the new
    /// `selectedRange`: nil when nothing is selected any more.
    public var onSelectionChange: ((Range<Int>?) -> Void)?

    /// Selects all of the text, with the selection handles shown, once the
    /// view is in a window and has text. Turn it off and on to select again.
    public var selectsAllWhenShown = false {
        didSet {
            guard selectsAllWhenShown != oldValue else { return }
            didSelectAllWhenShown = false
            selectAllIfNeeded()
        }
    }
    private var didSelectAllWhenShown = false

    private func selectAllIfNeeded() {
        guard selectsAllWhenShown, !didSelectAllWhenShown, window != nil, currentLayout.length > 0 else { return }
        didSelectAllWhenShown = true
        _ = becomeFirstResponder()
        selectAll(nil)
    }
    private let textInteraction = UITextInteraction(for: .nonEditable)
    private let emptyInputView = UIView()
    /// Holds the layers of tags' animations, above the tail layer.
    private let animationLayer = CALayer()
    /// Tags whose animations are playing, which the tiles leave out.
    private var playing: [TagKey: PlayingTag] = [:]
    private var playingKeys: Set<TagKey> = []
    /// Tags that have closed and wait for `tagAnimationTiming` to let them
    /// play; the tiles draw them without their shapes.
    private var waiting: Set<TagKey> = []
    /// Waiting tags the app has asked to play (`playTagAnimations()`).
    private var requested: Set<TagKey> = []
    /// No more text is coming to the document on screen.
    private var isFinished = false
    private var waitingCheckScheduled = false
    /// The last layout passed over for coming from a replaced source.
    private var skippedOutput: LayoutEngine.Output?
    private var hiding: TagHiding { TagHiding(playing: playingKeys, waiting: waiting) }

    private struct PlayingTag {
        let tag: AnimatedTag
        let layer: CALayer
        /// When it started, telling apart two plays of one tag.
        let start: CFTimeInterval
        let signpost: OSSignpostIntervalState
    }

    /// The drawn text, in fixed-height tiles that exist only near the visible
    /// area. Memory stays flat however long the document is, and an update
    /// redraws only the tiles it touches.
    private var tiles: [Int: CanvasView] = [:]
    private var spareTiles: [CanvasView] = []
    private let tileHeight: CGFloat = 256
    private var scrollObservation: NSKeyValueObservation?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    deinit {
        engine.shutDown()
    }

    private func setUp() {
        backgroundColor = .clear
        isOpaque = false
        canvas.isUserInteractionEnabled = false
        canvas.backgroundColor = .clear
        addSubview(canvas)
        tailLayer.isHidden = true
        tailLayer.zPosition = 1
        tailLayer.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
        canvas.layer.addSublayer(tailLayer)
        animationLayer.zPosition = 2
        animationLayer.actions = ["bounds": NSNull(), "position": NSNull(), "sublayers": NSNull()]
        canvas.layer.addSublayer(animationLayer)
        NotificationCenter.default.addObserver(self, selector: #selector(reduceMotionChanged),
                                               name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        engine.setOutputHandler { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.installFromEngine() }
            }
        }
        textInteraction.textInput = self
        addInteraction(textInteraction)
        let linkTap = UITapGestureRecognizer(target: self, action: #selector(handleLinkTap(_:)))
        linkTap.delegate = self
        addGestureRecognizer(linkTap)
        self.linkTap = linkTap
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitDisplayScale.self]) { (view: TranscriptTextView, _) in
            // The tiles take over everything, in the new colours; the tail
            // starts again, in them too, with the next append. Animations,
            // drawn in the old ones, end.
            view.finishAllAnimations()
            view.updateTailStyle()
            view.handTailToTiles()
            view.tiles.values.forEach { $0.setNeedsDisplay() }
        }
    }

    // MARK: Links

    private var linkTap: UITapGestureRecognizer?

    private func linkURL(at point: CGPoint) -> URL? {
        currentLayout.link(at: point).flatMap { URL(string: $0) }
    }

    @objc private func handleLinkTap(_ recognizer: UITapGestureRecognizer) {
        if recognizer.state == .ended, let url = linkURL(at: recognizer.location(in: self)) {
            openLink(url)
        }
    }

    /// The link tap only takes part when the touch is on a link, so taps
    /// elsewhere go to the selection gestures untouched.
    public override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === linkTap {
            return linkURL(at: gestureRecognizer.location(in: self)) != nil
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                  shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer === linkTap
    }

    // MARK: Viewport drawing

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        scrollObservation = nil
        updateTailStyle()
        updateAnimationsEnabled()
        guard window != nil else {
            handTailToTiles()
            return
        }
        var ancestor = superview
        while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
        if let scrollView = ancestor as? UIScrollView {
            scrollObservation = scrollView.observe(\.contentOffset) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateCanvas() }
            }
        }
        updateCanvas()
        selectAllIfNeeded()
    }

    /// The part of this view currently on screen, or all of it outside a scroll view.
    private var visibleRect: CGRect {
        var ancestor = superview
        while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
        guard let scrollView = ancestor as? UIScrollView else { return bounds }
        return convert(scrollView.bounds, from: scrollView).intersection(bounds)
    }

    /// Adds and removes tiles as the visible area moves, and marks the tiles
    /// that need drawing again.
    ///
    /// - Parameters:
    ///   - forceRedraw: the content changed, so existing tiles are stale.
    ///   - changed: with `forceRedraw`, the vertical band that changed, if known.
    /// Marks the parts of existing tiles between those y's for drawing. Tiles
    /// made later draw everything anyway.
    private func redrawTiles(in range: ClosedRange<CGFloat>) {
        for (index, tile) in tiles {
            let minY = CGFloat(index) * tileHeight
            let top = max(range.lowerBound - minY - 2, 0)
            let bottom = min(range.upperBound - minY + 2, tileHeight)
            if top < bottom {
                tile.setNeedsDisplay(CGRect(x: 0, y: top, width: tile.bounds.width, height: bottom - top))
            }
        }
    }

    private func updateCanvas(forceRedraw: Bool = false, changed: ClosedRange<CGFloat>? = nil) {
        // Tags waiting to be on screen may be now.
        if !waiting.isEmpty, tagAnimationTiming.contains(.whenVisible) { startWaitingTagsSoon() }
        let visible = visibleRect
        guard !visible.isNull, visible.height > 0, bounds.width > 0 else {
            if forceRedraw { tiles.values.forEach { $0.setNeedsDisplay() } }
            return
        }
        // Keep half a screen of drawn content above and below what is visible.
        let covered = visible.insetBy(dx: 0, dy: -visible.height / 2).intersection(bounds)
        let first = Int((covered.minY / tileHeight).rounded(.down))
        let last = max(Int(((covered.maxY - 0.5) / tileHeight).rounded(.down)), first)

        for (index, tile) in tiles where index < first || index > last {
            tile.isHidden = true
            spareTiles.append(tile)
            tiles[index] = nil
        }
        for index in first...last {
            // Wider than the view: tags' shapes may draw past the text column.
            let side = TranscriptPath.maximumSideOverhang
            let frame = CGRect(x: -side, y: CGFloat(index) * tileHeight, width: bounds.width + 2 * side, height: tileHeight)
            if let tile = tiles[index] {
                if tile.frame != frame {
                    tile.frame = frame
                    tile.setNeedsDisplay()
                } else if forceRedraw {
                    if let changed {
                        let top = max(changed.lowerBound - frame.minY - 2, 0)
                        let bottom = min(changed.upperBound - frame.minY + 2, tileHeight)
                        if top < bottom {
                            tile.setNeedsDisplay(CGRect(x: 0, y: top, width: frame.width, height: bottom - top))
                        }
                    } else {
                        tile.setNeedsDisplay()
                    }
                }
            } else {
                let tile = spareTiles.popLast() ?? makeTile()
                tile.frame = frame
                tile.isHidden = false
                tile.setNeedsDisplay()
                tiles[index] = tile
            }
        }
    }

    private func makeTile() -> CanvasView {
        let tile = CanvasView()
        tile.owner = self
        // In the canvas, below the selection highlight and handles the system adds.
        canvas.addSubview(tile)
        return tile
    }

    fileprivate func drawContent(in context: CGContext, rect: CGRect) {
        var rect = rect
        if tailTop < rect.maxY {
            // The tail layer shows everything from its top down.
            rect.size.height = max(tailTop - rect.minY, 0)
            guard rect.height > 0 else { return }
            context.clip(to: rect)
        }
        let colors = resolvedColors()
        currentLayout.draw(in: context, dirtyRect: rect, text: colors.text, codeBackground: colors.codeBackground, accent: colors.accent,
                           dark: colors.dark, hiding: hiding)
    }

    private func resolvedColors() -> TailRenderer.Colors {
        TailRenderer.Colors(
            text: UIColor.label.resolvedColor(with: traitCollection).cgColor,
            codeBackground: UIColor.secondarySystemFill.resolvedColor(with: traitCollection).cgColor,
            accent: UIColor.tertiaryLabel.resolvedColor(with: traitCollection).cgColor,
            dark: traitCollection.userInterfaceStyle == .dark
        )
    }

    // MARK: Tail

    /// How often the text may change on screen: at most 60 times a second,
    /// like `TranscriptStream`'s updates. Even where the app can draw at
    /// 120 Hz, text that changes faster than that shows nothing new and
    /// doubles the work; scrolling is not affected.
    static func framesPerSecond(on screen: UIScreen) -> Int {
        min(screen.maximumFramesPerSecond, 60)
    }

    /// Tells the engine how to draw the tail: in this view's colours and at
    /// its screen's scale, or not at all outside a window.
    private func updateTailStyle() {
        if let window { engine.setFramesPerSecond(Self.framesPerSecond(on: window.screen)) }
        let enabled = window != nil && TranscriptDiagnostics.drawsTailOffMainThread
        engine.setTailStyle(colors: enabled ? resolvedColors() : nil, scale: traitCollection.displayScale)
    }

    /// Shows `tail`, or hides the tail layer if nil, and returns the band
    /// the tiles must redraw because the tail's top moved.
    private func showTail(_ tail: TailRenderer.Frame?) -> ClosedRange<CGFloat>? {
        let oldTop = tailTop
        if let tail {
            tailLayer.contentsScale = traitCollection.displayScale
            tailLayer.frame = CGRect(x: -TailRenderer.sideMargin, y: tail.top, width: bounds.width + 2 * TailRenderer.sideMargin,
                                     height: TailRenderer.height)
            tailLayer.contents = tail.surface
            tailLayer.isHidden = false
            tailTop = tail.top
        } else {
            tailLayer.isHidden = true
            tailLayer.contents = nil
            tailTop = .greatestFiniteMagnitude
        }
        guard tailTop != oldTop else { return nil }
        // What the tail stopped covering, or started covering, is the tiles' job now.
        let lower = min(oldTop, tailTop)
        let upper = max(oldTop, tailTop)
        let end = (installed?.height ?? lower) + TranscriptPath.maximumOverhang
        return lower...(upper == .greatestFiniteMagnitude ? max(end, lower) : upper)
    }

    /// Hands everything back to the tiles and frees the tail's surfaces, once
    /// updates have stopped for a moment (or the tail cannot be used).
    private func handTailToTiles() {
        guard tailTop != .greatestFiniteMagnitude else { return }
        engine.settleTail()
        if let band = showTail(nil) {
            updateCanvas(forceRedraw: true, changed: band)
        }
    }

    private static let settleDelay: CFTimeInterval = 1

    /// Hands the tail to the tiles once no new one has come for a second.
    /// One check is pending at a time; it waits again if tails kept coming.
    private func scheduleTailSettling(after delay: CFTimeInterval = TranscriptTextView.settleDelay) {
        guard !settleCheckScheduled else { return }
        settleCheckScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.settleCheckScheduled = false
                let quiet = CACurrentMediaTime() - self.lastTailShown
                if quiet >= Self.settleDelay {
                    self.handTailToTiles()
                } else if self.tailTop != .greatestFiniteMagnitude {
                    self.scheduleTailSettling(after: Self.settleDelay - quiet)
                }
            }
        }
    }

    // MARK: Layout

    /// Installs what the engine finished, if it still fits the view.
    private func installFromEngine() {
        guard var output = engine.takeOutput() else { return }
        // A layout passed over because its source had just been replaced,
        // which this one builds on: a finished stream's last layout, and its
        // document's. Installed together, they are still an append.
        if let skipped = skippedOutput {
            skippedOutput = nil
            if output.base === skipped.layout {
                output = .merging(skipped, output)
            } else {
                engine.settleAnimations(skipped.started + skipped.waiting)
            }
        }
        guard output.source == source, output.layout.width == bounds.width, output.layout.style == style else {
            if output.source < source, output.layout.width == bounds.width, output.layout.style == style {
                // From the source just replaced: kept in case the next
                // layout, from the new one, builds on it.
                skippedOutput = output
                return
            }
            // Made for an earlier width or style; a synchronous relayout
            // has replaced it or is about to.
            engine.settleAnimations(output.started + output.waiting)
            return
        }
        let isAppend = output.isAppend && output.base != nil && output.base === installed
        install(output.layout, changedTop: isAppend ? output.changedTop : nil, tail: output.tail,
                restyled: isAppend ? output.restyled : [], started: output.started, waiting: output.waiting,
                isFinished: output.isFinished)
        // A tail drawn while a tag was in another state than it is now (its
        // animation has started or ended since): the tiles draw that part.
        if output.tail != nil, output.hidden != hiding {
            handTailToTiles()
        }
    }

    /// Lays out synchronously, for when the view cannot wait for the
    /// background: no layout on screen yet, or a new width or style.
    private func relayoutNow() {
        guard bounds.width > 0, let result = engine.relayout(width: bounds.width, style: style) else { return }
        skippedOutput = nil
        guard result.source == source else { return }
        install(result.layout, changedTop: nil, tail: nil, isFinished: result.isFinished)
    }

    private func layOutNowIfNothingIsShown() {
        if installed == nil { relayoutNow() }
    }

    /// Puts `layout` on screen.
    ///
    /// - Parameter changedTop: the layout only added content at the end of
    ///   the installed one, and nothing above this y changed. Existing
    ///   positions and selection geometry are then still valid and the
    ///   system is not told the text changed: that notification cancels an
    ///   in-flight selection gesture, and a streaming response would send it
    ///   many times a second. Only the band below this y is redrawn.
    ///
    /// - Parameter tail: the end of the document, drawn on the layout queue,
    ///   to show instead of drawing it in the tiles. It is shown in the same
    ///   transaction as the layout, so the two always match.
    /// - Parameter restyled: with `changedTop`, blocks above it drawn
    ///   differently in place; only those are drawn again, not all below them.
    /// - Parameter started: animated tags that closed in this update, whose
    ///   animations start now.
    /// - Parameter waiting: animated tags that closed in this update and
    ///   wait for `tagAnimationTiming` to let them play.
    /// - Parameter isFinished: no more text is coming.
    private func install(_ layout: DocumentLayout, changedTop: CGFloat?, tail: TailRenderer.Frame?, restyled: [CGRect] = [],
                         started: [TagKey] = [], waiting newlyWaiting: [TagKey] = [], isFinished: Bool = false) {
        self.isFinished = isFinished
        TranscriptDiagnostics.count(\.installs)
        let old = installed
        let isAppend = changedTop != nil && old != nil
        if !isAppend { inputDelegate?.textWillChange(self) }
        installed = layout
        if let current = selection {
            let length = layout.length
            selection = min(current.lowerBound, length)..<min(current.upperBound, length)
        }
        reportHeightIfChanged()
        selectAllIfNeeded()

        let moved = showTail(tail)
        if tail != nil {
            lastTailShown = CACurrentMediaTime()
            scheduleTailSettling()
        }
        if isAppend, let changedTop, let old {
            // Only what changed above the tail's top, plus whatever the tail
            // stopped or started covering, needs the tiles.
            var lower = moved?.lowerBound ?? .greatestFiniteMagnitude
            var upper = moved?.upperBound ?? -.greatestFiniteMagnitude
            if changedTop < tailTop {
                lower = min(lower, changedTop)
                // Tags' shapes may reach a little below the text.
                upper = max(upper, min(max(old.height + TranscriptPath.maximumOverhang, layout.height + TranscriptPath.maximumOverhang,
                                           changedTop), tailTop))
            }
            if lower <= upper {
                updateCanvas(forceRedraw: true, changed: lower...upper)
            } else {
                updateCanvas()
            }
            // The tail drew the restyled parts below its top.
            for rect in restyled where rect.minY < tailTop {
                redrawTiles(in: rect.minY...min(rect.maxY, tailTop))
            }
        } else {
            updateCanvas(forceRedraw: true)
        }

        if isAppend {
            // A playing tag whose glyphs moved (its line wrapped otherwise)
            // ends where it is.
            for (key, play) in playing where layout.animatedTag(key).map({ !$0.isPlaced(like: play.tag) }) ?? true {
                finishAnimation(key)
            }
            for key in started { startAnimation(key, in: layout) }
            waiting.formUnion(newlyWaiting)
            startWaitingTagsSoon()
        } else {
            // Everything was drawn again, at rest.
            removeAllAnimations()
            engine.settleAnimations(started + newlyWaiting)
        }

        if !isAppend {
            inputDelegate?.textDidChange(self)
            refreshSelectionDisplay()
        }
    }

    // MARK: Tag animations

    @objc private func reduceMotionChanged() {
        updateAnimationsEnabled()
    }

    private func updateAnimationsEnabled() {
        let enabled = animatesTags && window != nil && !UIAccessibility.isReduceMotionEnabled
        if animatesTags, window != nil, UIAccessibility.isReduceMotionEnabled {
            animationLog.debug("Tags are not animated: Reduce Motion is on")
        }
        engine.setAnimationsEnabled(enabled, immediately: tagAnimationTiming == .immediately)
        if !enabled {
            finishAllAnimations()
            showWaitingTagsAtRest()
        }
    }

    /// Starts waiting tags on the next turn of the run loop. What lets them
    /// play (the stream finishing, the app's request, a scroll) usually comes
    /// with other work in the same frame, such as the app showing what goes
    /// below a finished answer; starting an animation (drawing its glyphs,
    /// making its layers, redrawing the tiles) is better done in the next one.
    private func startWaitingTagsSoon() {
        guard !waiting.isEmpty, !waitingCheckScheduled else { return }
        waitingCheckScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.waitingCheckScheduled = false
                self.startWaitingTags()
            }
        }
    }

    /// Starts the waiting tags that `tagAnimationTiming` lets play now.
    private func startWaitingTags() {
        guard !waiting.isEmpty, let layout = installed else { return }
        let timing = tagAnimationTiming
        if timing.contains(.afterStreamFinishes), !isFinished { return }
        let visible = timing.contains(.whenVisible) ? visibleRect : .null
        var ready: [TagKey] = []
        for key in waiting {
            if timing.contains(.whenRequested), !requested.contains(key) { continue }
            if timing.contains(.whenVisible) {
                guard window != nil, let tag = layout.animatedTag(key), Self.isOnScreen(tag.band, in: visible) else { continue }
            }
            ready.append(key)
        }
        guard !ready.isEmpty else { return }
        for key in ready.sorted(by: { ($0.block, $0.start) < ($1.block, $1.start) }) {
            waiting.remove(key)
            requested.remove(key)
            engine.playAnimations([key])
            startAnimation(key, in: layout, wasWaiting: true)
        }
    }

    /// Whether a tag's rows count as on screen: all of them, or for a tag
    /// taller than what is visible, some of them.
    private static func isOnScreen(_ band: ClosedRange<CGFloat>, in visible: CGRect) -> Bool {
        guard !visible.isNull, visible.height > 0 else { return false }
        if band.upperBound - band.lowerBound > visible.height {
            return band.upperBound > visible.minY && band.lowerBound < visible.maxY
        }
        return band.lowerBound >= visible.minY && band.upperBound <= visible.maxY
    }

    /// Draws every waiting tag as it ends up, shapes and all, for when it
    /// can no longer play.
    private func showWaitingTagsAtRest() {
        guard !waiting.isEmpty else { return }
        let keys = waiting
        waiting.removeAll()
        requested.removeAll()
        engine.settleAnimations(keys)
        for key in keys {
            guard let tag = installed?.animatedTag(key) else { continue }
            let band = band(of: tag)
            // The tail was drawn without the tag's shapes.
            if tailTop < band.upperBound { handTailToTiles() }
            redrawTiles(in: band)
        }
    }

    /// Plays `key`'s animation over the text, which from now on leaves it out.
    ///
    /// - Parameter wasWaiting: it waited for its timing, and the tail, drawn
    ///   when it was waiting, still shows its glyphs.
    private func startAnimation(_ key: TagKey, in layout: DocumentLayout, wasWaiting: Bool = false) {
        if playing[key] != nil { finishAnimation(key) }
        guard let tag = layout.animatedTag(key) else {
            engine.settleAnimations([key])
            return
        }
        if wasWaiting, tailTop < band(of: tag).upperBound { handTailToTiles() }
        let animation = tag.animation.animation(for: tag.fragments)
        let colors = resolvedColors()
        let scale = traitCollection.displayScale
        let sprites = TagAnimationPlayer.sprites(for: tag, animation: animation,
                                                 appearance: .init(text: colors.text, dark: colors.dark, scale: scale))
        let start = CACurrentMediaTime()
        // No transaction of its own: the layers go to the screen in the same
        // commit as the tiles and the tail that stop drawing the tag. (An
        // explicit one, outside UIKit's, would commit on its own, and the
        // glyphs could show twice for a frame.) The layers take no implicit
        // animations (`TagAnimationPlayer.StillLayer`).
        let layer = TagAnimationPlayer.makeLayer(sprites: sprites, animation: animation, scale: scale, beginTime: start)
        animationLayer.addSublayer(layer)
        let signpost = animationSignposter.beginInterval("Tag animation", id: animationSignposter.makeSignpostID(),
                                                         "\(key.name, privacy: .public)")
        playing[key] = PlayingTag(tag: tag, layer: layer, start: start, signpost: signpost)
        playingKeys.insert(key)
        animationLog.debug("""
            Playing <\(key.name, privacy: .public)>: \(sprites.count) sprites on \(tag.parts.count) lines, \
            \(animation.duration, format: .fixed(precision: 2)) s
            """)
        redrawTiles(in: band(of: tag))
        DispatchQueue.main.asyncAfter(deadline: .now() + animation.duration) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.playing[key]?.start == start else { return }
                self.finishAnimation(key)
            }
        }
    }

    /// Ends `key`'s animation: the tiles and the tail draw the tag again, in
    /// the same transaction as its layers go.
    private func finishAnimation(_ key: TagKey) {
        guard let play = playing.removeValue(forKey: key) else { return }
        animationSignposter.endInterval("Tag animation", play.signpost)
        playingKeys.remove(key)
        engine.settleAnimations([key])
        let band = band(of: play.tag)
        // The tail was drawn without the tag: the tiles take over from it.
        if tailTop < band.upperBound { handTailToTiles() }
        redrawTiles(in: band)
        play.layer.removeFromSuperlayer()
    }

    private func finishAllAnimations() {
        for key in Array(playing.keys) { finishAnimation(key) }
    }

    /// Drops every animation without redrawing, for when everything is
    /// being drawn again anyway.
    private func removeAllAnimations() {
        engine.settleAnimations(waiting)
        waiting.removeAll()
        requested.removeAll()
        guard !playing.isEmpty else { return }
        engine.settleAnimations(playingKeys)
        for play in playing.values {
            play.layer.removeFromSuperlayer()
            animationSignposter.endInterval("Tag animation", play.signpost)
        }
        playing.removeAll()
        playingKeys.removeAll()
    }

    /// The rows a tag's drawing can change, its shapes' reach included.
    private func band(of tag: AnimatedTag) -> ClosedRange<CGFloat> {
        let overhang = TranscriptPath.maximumOverhang
        return (tag.band.lowerBound - overhang)...(tag.band.upperBound + overhang)
    }

    /// Asks the system to re-read selection geometry, e.g. after a reflow or a
    /// programmatic selection change. Gestures do this on their own.
    private func refreshSelectionDisplay() {
        guard let selection, !selection.isEmpty else { return }
        for case let display as UITextSelectionDisplayInteraction in interactions {
            display.isActivated = true
            display.setNeedsSelectionUpdate()
        }
    }

    private var reportedHeight: CGFloat = -1

    /// Asks the superview (or SwiftUI) to measure the view again, but only
    /// when the text's height actually changed. Most streamed chunks extend
    /// the last line, so this happens a few times a second, not per chunk.
    private func reportHeightIfChanged() {
        let height = ceil(installed?.height ?? 0)
        guard height != reportedHeight else { return }
        reportedHeight = height
        invalidateIntrinsicContentSize()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        canvas.frame = bounds
        animationLayer.frame = canvas.bounds
        if bounds.width > 0, installed?.width != bounds.width {
            relayoutNow()
            refreshSelectionDisplay()
        }
        updateCanvas()
    }

    public override func sizeThatFits(_ size: CGSize) -> CGSize {
        let width = size.width.isFinite && size.width > 0 ? size.width : max(bounds.width, 1)
        if let installed, installed.width == width {
            return CGSize(width: width, height: ceil(installed.height))
        }
        // Kept by the engine, so the relayout when the view takes this width is free.
        return CGSize(width: width, height: ceil(engine.measure(width: width, style: style)))
    }

    public override var intrinsicContentSize: CGSize {
        guard let installed else { return CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric) }
        return CGSize(width: UIView.noIntrinsicMetric, height: ceil(installed.height))
    }

    // MARK: Responder

    public override var canBecomeFirstResponder: Bool { isSelectable }

    /// Without selection, only links take touches.
    public override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard super.point(inside: point, with: event) else { return false }
        return isSelectable || linkURL(at: point) != nil
    }

    /// Read-only: an empty input view keeps the keyboard from appearing.
    public override var inputView: UIView? { emptyInputView }

    public override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(copy(_:)):
            return !(selection?.isEmpty ?? true)
        case #selector(selectAll(_:)):
            return currentLayout.length > 0 && selection != 0..<currentLayout.length
        case #selector(paste(_:)), #selector(cut(_:)), #selector(delete(_:)):
            return false
        default:
            return super.canPerformAction(action, withSender: sender)
        }
    }

    public override func copy(_ sender: Any?) {
        guard let selection, !selection.isEmpty else { return }
        UIPasteboard.general.string = shownDocument.copyText(in: selection)
    }

    public override func selectAll(_ sender: Any?) {
        select(0..<currentLayout.length)
    }

    /// Selects a range of the document's flat UTF-16 offset space, or clears
    /// the selection when `range` is nil.
    public func select(_ range: Range<Int>?) {
        inputDelegate?.selectionWillChange(self)
        selection = range.map { clamp($0.lowerBound)..<clamp($0.upperBound) }
        inputDelegate?.selectionDidChange(self)
        refreshSelectionDisplay()
    }

    /// The currently selected text, if any.
    public var selectedText: String? {
        guard let selection, !selection.isEmpty else { return nil }
        return shownDocument.text(in: selection)
    }

    // MARK: UITextInput — positions and ranges

    private func offset(of position: UITextPosition) -> Int {
        (position as? TranscriptTextPosition)?.offset ?? 0
    }

    private func range(of textRange: UITextRange) -> Range<Int> {
        (textRange as? TranscriptTextRange)?.range ?? 0..<0
    }

    private func clamp(_ offset: Int) -> Int {
        min(max(offset, 0), currentLayout.length)
    }

    public var beginningOfDocument: UITextPosition { TranscriptTextPosition(offset: 0) }
    public var endOfDocument: UITextPosition { TranscriptTextPosition(offset: currentLayout.length) }

    public func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        let a = clamp(offset(of: fromPosition))
        let b = clamp(offset(of: toPosition))
        return TranscriptTextRange(range: min(a, b)..<max(a, b))
    }

    public func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        let target = self.offset(of: position) + offset
        guard target >= 0, target <= currentLayout.length else { return nil }
        return TranscriptTextPosition(offset: target)
    }

    public func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        let start = self.offset(of: position)
        switch direction {
        case .left: return TranscriptTextPosition(offset: clamp(start - offset))
        case .right: return TranscriptTextPosition(offset: clamp(start + offset))
        case .up, .down:
            let caret = currentLayout.caretRect(at: start)
            let step = caret.height * CGFloat(offset) * (direction == .up ? -1 : 1)
            let target = currentLayout.closestOffset(to: CGPoint(x: caret.midX, y: caret.midY + step))
            return TranscriptTextPosition(offset: target)
        @unknown default: return nil
        }
    }

    public func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        let a = offset(of: position)
        let b = offset(of: other)
        return a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }

    public func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        offset(of: toPosition) - offset(of: from)
    }

    public func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        let range = self.range(of: range)
        switch direction {
        case .left, .up: return TranscriptTextPosition(offset: range.lowerBound)
        case .right, .down: return TranscriptTextPosition(offset: range.upperBound)
        @unknown default: return nil
        }
    }

    public func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        let start = offset(of: position)
        switch direction {
        case .left, .up: return TranscriptTextRange(range: clamp(start - 1)..<start)
        case .right, .down: return TranscriptTextRange(range: start..<clamp(start + 1))
        @unknown default: return nil
        }
    }

    // MARK: UITextInput — text and selection

    public func text(in range: UITextRange) -> String? {
        shownDocument.text(in: self.range(of: range))
    }

    public var selectedTextRange: UITextRange? {
        get { selection.map { TranscriptTextRange(range: $0) } }
        set { selection = newValue.map { range(of: $0) } }
    }

    public weak var inputDelegate: UITextInputDelegate?
    public private(set) lazy var tokenizer: UITextInputTokenizer = UITextInputStringTokenizer(textInput: self)

    // MARK: UITextInput — geometry

    public func caretRect(for position: UITextPosition) -> CGRect {
        currentLayout.caretRect(at: clamp(offset(of: position)))
    }

    public func firstRect(for range: UITextRange) -> CGRect {
        let range = self.range(of: range)
        return currentLayout.selectionRects(for: range).first ?? currentLayout.caretRect(at: range.lowerBound)
    }

    public func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        let rects = currentLayout.selectionRects(for: self.range(of: range))
        return rects.enumerated().map { index, rect in
            TranscriptSelectionRect(rect: rect, containsStart: index == 0, containsEnd: index == rects.count - 1)
        }
    }

    public func closestPosition(to point: CGPoint) -> UITextPosition? {
        TranscriptTextPosition(offset: currentLayout.closestOffset(to: point))
    }

    public func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
        let range = self.range(of: range)
        let offset = currentLayout.closestOffset(to: point)
        return TranscriptTextPosition(offset: min(max(offset, range.lowerBound), range.upperBound))
    }

    public func characterRange(at point: CGPoint) -> UITextRange? {
        let offset = currentLayout.closestOffset(to: point)
        guard offset < currentLayout.length else { return nil }
        return TranscriptTextRange(range: offset..<(offset + 1))
    }

    public func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection {
        .leftToRight
    }

    public func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}

    // MARK: UITextInput — editing (unsupported: the view is read-only)

    public var hasText: Bool { currentLayout.length > 0 }
    public func insertText(_ text: String) {}
    public func deleteBackward() {}
    public func replace(_ range: UITextRange, withText text: String) {}
    public var markedTextRange: UITextRange? { nil }
    public var markedTextStyle: [NSAttributedString.Key: Any]? {
        get { nil }
        set {}
    }
    public func setMarkedText(_ markedText: String?, selectedRange: NSRange) {}
    public func unmarkText() {}
}

// MARK: - Canvas

/// Draws the slice of the document that its frame covers.
private final class CanvasView: UIView {
    weak var owner: TranscriptTextView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ rect: CGRect) {
        TranscriptDiagnostics.count(\.tileDraws)
        guard let owner, let context = UIGraphicsGetCurrentContext() else { return }
        // Shift into the owner's coordinate space, where the layout lives.
        context.translateBy(x: -frame.minX, y: -frame.minY)
        owner.drawContent(in: context, rect: rect.offsetBy(dx: frame.minX, dy: frame.minY))
    }
}

// MARK: - Position, range and selection rect types

final class TranscriptTextPosition: UITextPosition {
    let offset: Int

    init(offset: Int) {
        self.offset = offset
        super.init()
    }
}

final class TranscriptTextRange: UITextRange {
    let range: Range<Int>

    init(range: Range<Int>) {
        self.range = range
        super.init()
    }

    override var start: UITextPosition { TranscriptTextPosition(offset: range.lowerBound) }
    override var end: UITextPosition { TranscriptTextPosition(offset: range.upperBound) }
    override var isEmpty: Bool { range.isEmpty }
}

final class TranscriptSelectionRect: UITextSelectionRect {
    private let storedRect: CGRect
    private let storedContainsStart: Bool
    private let storedContainsEnd: Bool

    init(rect: CGRect, containsStart: Bool, containsEnd: Bool) {
        storedRect = rect
        storedContainsStart = containsStart
        storedContainsEnd = containsEnd
        super.init()
    }

    override var rect: CGRect { storedRect }
    override var writingDirection: NSWritingDirection { .leftToRight }
    override var containsStart: Bool { storedContainsStart }
    override var containsEnd: Bool { storedContainsEnd }
    override var isVertical: Bool { false }
}
#endif
