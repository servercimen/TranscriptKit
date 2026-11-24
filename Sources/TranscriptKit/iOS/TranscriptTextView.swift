#if canImport(UIKit) && !os(watchOS)
import os
import UIKit

/// Why tags animate or not, at the debug level: shown in Xcode's console and
/// in Console with debug messages on, and not stored otherwise.
private let animationLog = Logger(subsystem: "TranscriptKit", category: "TagAnimations")
/// Each tag animation as an interval in Instruments' Points of Interest.
private let animationSignposter = OSSignposter(subsystem: "TranscriptKit", category: .pointsOfInterest)
/// Where a block that scrolls sideways stops, at the debug level, like `animationLog`.
private let sideScrollLog = Logger(subsystem: "TranscriptKit", category: "SideScroll")
/// Each replaced document that is laid out on the main thread, as an
/// interval in Instruments' Points of Interest.
private let replacementSignposter = OSSignposter(subsystem: "TranscriptKit", category: .pointsOfInterest)

/// A read-only text view that draws a whole transcript with Core Text and
/// exposes it to the system as one selectable document.
///
/// Selection handles, the loupe and the edit menu come from `UITextInteraction`;
/// this view only answers geometry and text queries through `UITextInput`.
///
/// Layout happens on a background queue. The view keeps showing, and
/// answering selection queries from, the last layout it installed until the
/// next one is ready, so text positions always match what is on screen.
/// With `replacementCrossfadeDuration`, a replaced document is laid out on
/// the main thread instead.
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
            guard isSelectable != oldValue, !isSelectable else { return }
            select(nil)
            if let textInteraction {
                removeInteraction(textInteraction)
                self.textInteraction = nil
            }
            if isFirstResponder { resignFirstResponder() }
        }
    }

    /// The text to show. Setting it while a `stream` is attached detaches the stream.
    public var document: TranscriptDocument {
        get { stream?.document ?? directDocument }
        set {
            let replacesStream = stream != nil
            guard replacesStream || newValue != directDocument else { return }
            let update = DocumentUpdate.choose(replacing: document, with: newValue, isLaidOut: installed != nil && bounds.width > 0,
                                               crossfade: replacementCrossfadeDuration)
            directDocument = newValue
            directSequence += 1
            laysOutDirectDocumentNow = update != .background
            if replacesStream {
                // Detaching submits `directDocument`, now the new one. Only
                // one document goes to the engine: an earlier one in between
                // would make the new one look like a replacement rather than
                // what the stream's text grew into.
                stream = nil
            } else {
                engine.submit(.init(document: newValue, source: source, sequence: directSequence, isFinished: true),
                              schedulesLayout: !laysOutDirectDocumentNow)
            }
            laysOutDirectDocumentNow = false
            if case .now(let crossfade) = update {
                replaceNow(crossfade: crossfade)
            } else {
                layOutNowIfNothingIsShown()
            }
        }
    }

    /// How long a replaced document takes to crossfade from the old text,
    /// or nil to lay it out in the background, as every other update (the
    /// default).
    ///
    /// With a duration, the view lays out a new `document` on the main
    /// thread at once when it does not add to the one before (see
    /// `TranscriptDocument.extends(_:)`). `sizeThatFits(_:)` and
    /// `intrinsicContentSize` then give the new height in the same update.
    /// The old drawing crossfades to the new one, as
    /// `UIView.transition(with:duration:options:animations:)` does with
    /// `.transitionCrossDissolve`. Zero shows the new text at once. While
    /// the crossfade plays, the drawing is clipped to the view's bounds and
    /// the space that tags' shapes may draw in (see
    /// `TranscriptPath.maximumOverhang`), so the old text does not show
    /// below a view that got shorter. A new replacement, a replacement with
    /// zero, and a new document from the background that does not add to
    /// the text stop a crossfade that plays.
    ///
    /// Text that only grows, and the updates of a `stream`, keep the
    /// background path. A new document that starts with the blocks of the
    /// old one, with the same ids, only grows the text: for example a
    /// summary that is the start of its details, parsed with the same
    /// `idPrefix`. It does not crossfade. Parse the two texts with different
    /// prefixes to crossfade between them. The first text after an empty
    /// document also only grows the text. A crossfade has no motion, so it
    /// also plays with Reduce Motion.
    public var replacementCrossfadeDuration: TimeInterval?

    /// The document setter lays out the direct document now, so the engine
    /// must not lay it out first.
    private var laysOutDirectDocumentNow = false

    /// A stream to show. The view then takes each update from the stream
    /// directly, in the background, without the app or SwiftUI setting `document`.
    public var stream: TranscriptStream? {
        didSet {
            guard stream !== oldValue else { return }
            if let oldValue, let sinkID { oldValue.detachSink(sinkID) }
            sinkID = nil
            source += 1
            guard let stream else {
                engine.submit(.init(document: directDocument, source: source, sequence: directSequence, isFinished: true),
                              schedulesLayout: !laysOutDirectDocumentNow)
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
            styleChanged()
            updateSidePan()
        }
    }

    /// `style` as layout uses it, with the Bold Text setting of the trait
    /// collection.
    private var layoutStyle: TranscriptStyle {
        style.withBoldText(traitCollection.legibilityWeight == .bold)
    }

    private func styleChanged() {
        emptyLayout = DocumentLayout(document: TranscriptDocument(), width: 1, style: layoutStyle)
        if bounds.width == 0, unsizedWidth > 0 {
            engine.layOutUntilPlaced(width: unsizedWidth, style: layoutStyle)
        }
        relayoutNow()
        updateTailStyle()
        updateFadeDuration()
    }

    /// How long text takes to fade in as it streams in, or nil to show it at
    /// once (the default). Each update's new text fades in on its own, so the
    /// fade follows the text as it arrives. Core Animation plays the fades;
    /// the text is drawn on the layout queue. Off with Reduce Motion and
    /// with a line limit.
    public var textFadeInDuration: TimeInterval? {
        didSet {
            guard textFadeInDuration != oldValue else { return }
            updateFadeDuration()
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

    /// Whether the tags with an animation that the view's first text already
    /// holds play it, each one time, as if they had just closed. Off by
    /// default: text that is complete when it is shown, such as an earlier
    /// message or a document set directly, shows its tags as they end up.
    ///
    /// The first text is the first layout with text that the view shows.
    /// `tagAnimationTiming` applies: with `.whenVisible`, each tag plays when
    /// it comes on screen. Tags that close later animate as usual. A view
    /// that is made again, as a lazy stack does with a row that scrolls back
    /// into view, plays them again. Set it before the view shows text.
    public var animatesTagsInFirstText = false

    /// Lets every tag waiting to animate now play, as soon as the rest of
    /// `tagAnimationTiming` allows. Tags that close later wait for the next
    /// call. Does nothing unless the timing includes `.whenRequested`.
    public func playTagAnimations() {
        waiting.request()
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
            engine.images.setLoader(imageLoader, onChange: imagesChanged)
            relayoutNow()
        }
    }

    /// Colors the code in code blocks, as a syntax highlighter does. It is
    /// called off the main thread with each code block's text and language,
    /// at most once at a time for each block, and a block shows its newest
    /// colors meanwhile. Code is drawn in the text color until its colors
    /// arrive. Not set by default.
    public var codeHighlighter: TranscriptCodeHighlighter? {
        didSet {
            engine.images.setOnChange(imagesChanged)
            engine.images.setHighlighter(codeHighlighter)
            relayoutNow()
        }
    }

    /// Draws LaTeX formulas: `\( … \)` inline, and `\[ … \]` and `$$ … $$`
    /// as display math. It is called off the main thread, once for each formula
    /// and font size in `mathCache`. Only the alpha of the image it returns is
    /// used: the formula is drawn in the text color. Not set by default.
    ///
    /// Until a formula is drawn, it is empty space of about its size. While
    /// the LaTeX of a formula changes, as when an app closes an open formula
    /// in each new snapshot of the text, the formula keeps its last image
    /// until the new one is drawn, and only its newest LaTeX waits to be
    /// drawn. If the renderer returns nil, the formula shows its LaTeX as
    /// written once that LaTeX stays the same for a second: LaTeX that is
    /// not complete yet can fail while it streams in.
    ///
    /// Views share `TranscriptMathCache.shared` by default, and a formula
    /// that one view drew shows in the others without a call to their
    /// renderers. Setting this property does not empty the cache. Give views
    /// whose renderers draw a formula differently a `mathCache` each, and
    /// call `removeAll()` on the cache when the renderer changes how it draws.
    public var mathRenderer: TranscriptMathRenderer? {
        didSet {
            engine.images.setOnChange(imagesChanged)
            engine.images.setMathRenderer(mathRenderer)
            relayoutNow()
        }
    }

    /// Keeps the formulas that `mathRenderer` draws, so that views that share
    /// a cache draw each formula once. `TranscriptMathCache.shared` by default.
    /// Give views whose renderers draw a formula differently a cache each.
    public var mathCache: TranscriptMathCache = .shared {
        didSet {
            guard mathCache !== oldValue else { return }
            engine.images.setMathCache(mathCache)
            relayoutNow()
        }
    }

    /// Waits until the view shows its final content: no layout, stream
    /// parse, image load, formula or code colors are pending, the last
    /// layout is on screen, and its tiles are drawn. Use it before a
    /// snapshot, or in a test.
    ///
    /// Work that keeps arriving, such as a stream that has not finished,
    /// does not hold it back: it returns at the first moment when nothing
    /// is pending. A cancelled task returns at once. An image that the
    /// loader returns nil for counts as done. A formula that the renderer
    /// returns nil for counts as done when it shows its LaTeX as written,
    /// about a second later. A load, a formula or a highlight that never ends
    /// holds it back: use a timeout, or cancel the task. Fades and tag
    /// animations that play are not waited for: to compare pixels, turn off
    /// `textFadeInDuration` and `animatesTags`.
    ///
    /// Give the view its size before the call. A view with no width lays
    /// out nothing, so it settles at once with no content.
    public func contentSettled() async {
        await settledWaiters.wait()
    }

    /// The words that VoiceOver says for a formula, for example from a
    /// library that turns LaTeX into speech. Called on the main thread. Not
    /// set by default: VoiceOver then reads the formula's LaTeX.
    public var mathAccessibilityLabel: ((TranscriptMath) -> String)? {
        didSet { invalidateAccessibilityElements() }
    }

    private let engine = LayoutEngine()
    private lazy var settledWaiters = makeSettledWaiters()

    private func makeSettledWaiters() -> ContentSettledWaiters {
        let waiters = ContentSettledWaiters(work: engine.work)
        waiters.stream = { [weak self] in self?.stream }
        waiters.layOut = { [weak self] in self?.layoutIfNeeded() }
        waiters.draw = { [weak self] in self?.drawTilesNow() }
        return waiters
    }

    /// Lays out again when pictures, formulas or code colors arrive. The
    /// image store calls it on main.
    private var imagesChanged: @Sendable () -> Void {
        { [weak self] in
            MainActor.assumeIsolated { self?.relayoutNow(keepingFades: true) }
        }
    }

    /// Holds the tiles, and the tail layer above them, below the system's
    /// selection views.
    private let canvas = UIView()
    /// Holds the canvas, in the coordinates of this view. While a replaced
    /// document crossfades, it clips the canvas to the bounds and the space
    /// that tags' shapes may draw in, so that the old drawing does not show
    /// outside the view's new height.
    private let canvasClip = UIView()
    /// Counts the crossfades, so that the end of an old one does not stop
    /// the clip of a newer one.
    private var crossfadeCount = 0
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
    private lazy var emptyLayout = DocumentLayout(document: TranscriptDocument(), width: 1, style: layoutStyle)
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
    /// when nothing is selected. `document.text(in:)` gives its text. Under
    /// a line limit, a selection that reaches the end of the text shown
    /// also covers the text that the limit leaves out.
    public var selectedRange: Range<Int>? {
        guard let selection, !selection.isEmpty else { return nil }
        return currentLayout.documentRange(forSelection: selection)
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
    /// The system's selection gestures and edit menu. Setting them up costs
    /// more than laying out a short text, and most views in a scrolling list
    /// are never touched, so they are added when a touch first reaches the
    /// view (see `point(inside:with:)`) or the app selects text.
    private var textInteraction: UITextInteraction?
    private let emptyInputView = UIView()
    /// Holds the layers of tags' animations, above the tail layer.
    private let animationLayer = CALayer()
    /// Holds the text that fades in, above the tail layer.
    private let fadeLayer = CALayer()
    /// Each fade's layers, one for each line it is on, by fade.
    private var fadeLayers: [Int: [CALayer]] = [:]
    /// Text from this flat offset on fades in, so the tiles leave it out.
    private var fadingFrom: Int?
    /// When the newest fade on screen ends.
    private var fadesEnd: CFTimeInterval = 0
    private var fadeSettleScheduled = false
    /// Tags whose animations are playing, which the tiles leave out.
    private var playing: [TagKey: PlayingTag] = [:]
    private var playingKeys: Set<TagKey> = []
    /// Tags that have closed and wait for `tagAnimationTiming` to let them
    /// play; the tiles draw them without their shapes.
    private var waiting = WaitingTags()
    /// No more text is coming to the document on screen.
    private var isFinished = false
    private var waitingCheckScheduled = false
    private var visibilityCheckScheduled = false
    private var visibilityCheckDelay = TranscriptTextView.firstVisibilityCheck
    private static let firstVisibilityCheck: TimeInterval = 0.25
    private static let lastVisibilityCheck: TimeInterval = 1
    /// A layout with text has been on screen.
    private var hasShownText = false
    /// The last layout passed over for coming from a replaced source.
    private var skippedOutput: LayoutEngine.Output?
    private var hiding: TagHiding { TagHiding(playing: playingKeys, waiting: waiting.keys, fadingFrom: fadingFrom) }

    private struct PlayingTag {
        let tag: AnimatedTag
        let layer: CALayer
        /// When it started, telling apart two plays of one tag.
        let start: CFTimeInterval
        let signpost: OSSignpostIntervalState
    }

    /// The drawn text, in tiles that exist only near the visible area (see
    /// `TileGrid`). Memory stays flat however long the document is, and an
    /// update redraws only the tiles it touches.
    private var tiles: [Int: CanvasView] = [:]
    private var spareTiles: [CanvasView] = []
    private let tileHeight = TileGrid.height
    private var scrollObservation: NSKeyValueObservation?
    private var canvasCheckScheduled = false

    /// How far the blocks that scroll sideways are scrolled (see
    /// `TranscriptStyle.codeWraps` and `displayMathScrolls`).
    private var sideScroll = SideScroll()
    /// Scrolls a block sideways. It exists while the style lets blocks scroll.
    private var sidePan: UIPanGestureRecognizer?
    /// The block that the pan moves: its id, its entry's index, and its offset when the pan began.
    private var sidePanTarget: (id: String, index: Int, start: CGFloat)?
    /// A block that goes on moving after a pan, slowing down as in a scroll view.
    private var sideDeceleration: (id: String, index: Int, velocity: CGFloat, time: CFTimeInterval, link: CADisplayLink)?
    /// The touch that stopped a moving block: it opens no link.
    private weak var stoppingTouch: UITouch?
    /// No text fades in while a block that text streams into moves sideways.
    private var fadesHeld = false
    /// The tail is hidden, but the engine still draws one (see `hideTail()`).
    private var tailNeedsSettling = false

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
        canvasClip.isUserInteractionEnabled = false
        canvasClip.backgroundColor = .clear
        canvasClip.addSubview(canvas)
        addSubview(canvasClip)
        tailLayer.isHidden = true
        tailLayer.zPosition = 1
        tailLayer.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
        canvas.layer.addSublayer(tailLayer)
        fadeLayer.zPosition = 1.5
        fadeLayer.actions = ["bounds": NSNull(), "position": NSNull(), "sublayers": NSNull()]
        canvas.layer.addSublayer(fadeLayer)
        animationLayer.zPosition = 2
        animationLayer.actions = ["bounds": NSNull(), "position": NSNull(), "sublayers": NSNull()]
        canvas.layer.addSublayer(animationLayer)
        NotificationCenter.default.addObserver(self, selector: #selector(reduceMotionChanged),
                                               name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(otherViewBecameFirstResponder(_:)),
                                               name: Self.didBecomeFirstResponder, object: nil)
        engine.setOutputHandler { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.installFromEngine() }
            }
        }
        let linkTap = UITapGestureRecognizer(target: self, action: #selector(handleLinkTap(_:)))
        linkTap.delegate = self
        addGestureRecognizer(linkTap)
        self.linkTap = linkTap
        let colorTraits: [UITrait] = [UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self, UITraitDisplayScale.self]
        registerForTraitChanges(colorTraits) { (view: TranscriptTextView, _) in
            // The tiles take over everything, in the new colours; the tail
            // starts again, in them too, with the next append. Animations,
            // drawn in the old ones, end.
            view.finishAllAnimations()
            view.settleFades()
            view.updateTailStyle()
            view.handTailToTiles()
            view.tiles.values.forEach { $0.setNeedsDisplay() }
        }
        registerForTraitChanges([UITraitLegibilityWeight.self]) { (view: TranscriptTextView, previous: UITraitCollection) in
            guard view.style.withBoldText(previous.legibilityWeight == .bold) != view.layoutStyle else { return }
            view.styleChanged()
            // Later: the trait can change during a SwiftUI update, which must
            // not change SwiftUI state.
            if view.bounds.width == 0, view.unsizedWidth > 0 {
                DispatchQueue.main.async { [weak view] in
                    MainActor.assumeIsolated { view?.onHeightChangeWhileUnsized?() }
                }
            }
        }
    }

    // MARK: Links

    private var linkTap: UITapGestureRecognizer?

    private func linkURL(at point: CGPoint) -> URL? {
        currentLayout.link(at: point, scroll: sideScroll).flatMap { URL(string: $0) }
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
        if gestureRecognizer === sidePan { return sidePanShouldBegin() }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                  shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer === linkTap
    }

    /// The scroll views around the view wait for a sideways pan to fail, so
    /// that a sideways drag in a block that scrolls moves the block. The pan
    /// fails as soon as the drag goes up or down, or starts outside such a block.
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                  shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === sidePan, let scrollView = other.view as? UIScrollView,
              other === scrollView.panGestureRecognizer else { return false }
        return isDescendant(of: scrollView)
    }

    /// The sideways pan takes only touches in blocks that scroll, so that it
    /// fails at once elsewhere and the scroll views around do not wait for it.
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        let point = touch.location(in: self)
        // A touch on a block that still moves after a pan stops it, and opens
        // no link, as in a scroll view.
        if let moving = sideDeceleration, let index = currentLayout.sideScrollingEntryIndex(at: point),
           currentLayout.entry(at: index).layout.block.id == moving.id {
            stopSideDeceleration()
            stoppingTouch = touch
        } else if stoppingTouch !== touch {
            stoppingTouch = nil
        }
        if gestureRecognizer === linkTap { return touch !== stoppingTouch }
        if gestureRecognizer === sidePan { return currentLayout.sideScrollingEntryIndex(at: point) != nil }
        return true
    }

    // MARK: Sideways scrolling

    /// Adds the sideways pan when the style lets blocks scroll, and removes it when not.
    private func updateSidePan() {
        let needed = !style.codeWraps || style.displayMathScrolls
        if needed, sidePan == nil {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleSidePan(_:)))
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            addGestureRecognizer(pan)
            sidePan = pan
        } else if !needed, let pan = sidePan {
            removeGestureRecognizer(pan)
            sidePan = nil
            sidePanTarget = nil
            stopSideDeceleration()
            releaseFades()
        }
    }

    /// Where the pan's touch went down: the pan begins only after the touch
    /// has moved some way.
    private func startPoint(of pan: UIPanGestureRecognizer) -> CGPoint {
        let location = pan.location(in: self)
        let translation = pan.translation(in: self)
        return CGPoint(x: location.x - translation.x, y: location.y - translation.y)
    }

    /// See `DocumentLayout.sidePanEntryIndex(at:velocity:scroll:handles:)`.
    private func sidePanShouldBegin() -> Bool {
        guard let pan = sidePan else { return false }
        let handles = selectedRange.map { [$0.lowerBound, $0.upperBound] } ?? []
        return currentLayout.sidePanEntryIndex(at: startPoint(of: pan), velocity: pan.velocity(in: self), scroll: sideScroll,
                                               handles: handles) != nil
    }

    @objc private func handleSidePan(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            stopSideDeceleration()
            guard let index = currentLayout.sideScrollingEntryIndex(at: startPoint(of: pan)) else { return }
            let entry = currentLayout.entry(at: index)
            sidePanTarget = (entry.layout.block.id, index, sideScroll.offset(of: entry.layout))
            // The block moves from here on, without a jump for the distance the pan took to begin.
            pan.setTranslation(.zero, in: self)
            holdFades(whileMoving: index)
        case .changed:
            guard let target = sidePanTarget else { return }
            scrollBlock(target.id, to: target.start - pan.translation(in: self).x, hint: target.index)
        case .ended:
            guard let target = sidePanTarget else {
                releaseFades()
                return
            }
            sidePanTarget = nil
            logSideScroll(of: target.id, "Pan ended")
            startSideDeceleration(of: target.id, index: target.index, velocity: -pan.velocity(in: self).x)
        default:
            if sidePanTarget != nil, sideDeceleration == nil { releaseFades() }
            sidePanTarget = nil
        }
    }

    /// Fading text is drawn where its block was when the fade began. While
    /// the block at `index` moves sideways, text that streams into it shows
    /// at once, without a fade, until `releaseFades()`.
    private func holdFades(whileMoving index: Int) {
        let layout = currentLayout
        if index == layout.entryCount - 1, !isFinished, !fadesHeld {
            fadesHeld = true
            updateFadeDuration()
        }
        settleFades(reaching: layout.entry(at: index))
    }

    private func releaseFades() {
        guard fadesHeld else { return }
        fadesHeld = false
        updateFadeDuration()
    }

    /// Ends the fades if their text reaches into `entry`'s block.
    private func settleFades(reaching entry: DocumentLayout.Entry) {
        let from = fadingFrom ?? (fadeLayers.isEmpty ? nil : 0)
        if let from, from <= entry.start + entry.layout.length { settleFades() }
    }

    /// Scrolls the block with `id` sideways to `offset`, cut to what it can
    /// scroll, and draws it again. Returns the offset it got, or nil if the
    /// block is not on screen.
    @discardableResult
    private func scrollBlock(_ id: String, to offset: CGFloat, hint: Int? = nil) -> CGFloat? {
        let layout = currentLayout
        guard let index = layout.entryIndex(ofBlock: id, hint: hint) else { return nil }
        let entry = layout.entry(at: index)
        let clamped = min(max(offset, 0), entry.layout.maximumScrollOffset)
        guard clamped != sideScroll.offset(of: entry.layout) else { return clamped }
        sideScroll[id] = clamped
        engine.setSideScroll(sideScroll)
        let overhang = TranscriptPath.maximumOverhang
        let band = (entry.y - overhang)...(entry.frame.maxY + overhang)
        settleFades(reaching: entry)
        for key in playingKeys where key.block == id { finishAnimation(key) }
        // The tail shows the block at its old offset: the tiles draw it until the next tail.
        if tailTop < band.upperBound { hideTail() }
        redrawTiles(in: band)
        refreshSelectionDisplay()
        return clamped
    }

    /// Scrolls the block with `id` by most of its box, for a VoiceOver
    /// three-finger swipe in `direction`. Returns false if it cannot move that way.
    func accessibilityScrollBlock(_ id: String, _ direction: UIAccessibilityScrollDirection) -> Bool {
        guard let index = currentLayout.entryIndex(ofBlock: id) else { return false }
        let block = currentLayout.entry(at: index).layout
        let page = (block.scrollBox.width * 0.8).rounded()
        let start = sideScroll.offset(of: block)
        let target: CGFloat
        switch direction {
        case .left: target = start + page
        case .right: target = start - page
        default: return false
        }
        stopSideDeceleration()
        guard let reached = scrollBlock(id, to: target, hint: index), reached != start else { return false }
        let percent = Int((reached / block.maximumScrollOffset * 100).rounded())
        let format = NSLocalizedString("Scrolled sideways, %d percent",
                                       comment: "VoiceOver: how far a code block or formula is scrolled sideways")
        UIAccessibility.post(notification: .pageScrolled, argument: String(format: format, percent))
        return true
    }

    private func startSideDeceleration(of id: String, index: Int, velocity: CGFloat) {
        stopSideDeceleration()
        guard abs(velocity) > 20 else {
            logSideScroll(of: id, "Stopped")
            releaseFades()
            return
        }
        let link = CADisplayLink(target: SideScrollFrameTarget(view: self), selector: #selector(SideScrollFrameTarget.frame(_:)))
        link.add(to: .main, forMode: .common)
        sideDeceleration = (id, index, velocity, CACurrentMediaTime(), link)
    }

    private func stopSideDeceleration() {
        guard let moving = sideDeceleration else { return }
        moving.link.invalidate()
        sideDeceleration = nil
        logSideScroll(of: moving.id, "Stopped")
        releaseFades()
    }

    private func logSideScroll(of id: String, _ event: String) {
        guard let index = currentLayout.entryIndex(ofBlock: id) else { return }
        let block = currentLayout.entry(at: index).layout
        let offset = sideScroll.offset(of: block)
        let maximum = block.maximumScrollOffset
        sideScrollLog.debug(
            "\(event, privacy: .public): block \(id, privacy: .public) at \(offset, format: .fixed(precision: 1)) of \(maximum, format: .fixed(precision: 1)) points")
    }

    fileprivate func stepSideDeceleration(_ link: CADisplayLink) {
        guard var moving = sideDeceleration, moving.link === link else {
            link.invalidate()
            return
        }
        let now = CACurrentMediaTime()
        let step = SideScroll.decelerate(velocity: moving.velocity, for: now - moving.time)
        moving.velocity = step.velocity
        moving.time = now
        sideDeceleration = moving
        let target = sideScroll[moving.id] + step.distance
        guard let reached = scrollBlock(moving.id, to: target, hint: moving.index), reached == target,
              abs(moving.velocity) > 10 else {
            stopSideDeceleration()
            return
        }
    }

    // MARK: Viewport drawing

    public override func didMoveToSuperview() {
        super.didMoveToSuperview()
        cachedScrollView = nil
        hasNoScrollView = false
    }

    public override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        // A selectable `UITextView` can raise "UIPreviewTarget requires that
        // the container view is in a window" when its edit menu or drag
        // preview outlives its window. A cleared selection has neither.
        guard newWindow == nil else { return }
        if selection != nil { select(nil) }
        if isFirstResponder { resignFirstResponder() }
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        scrollObservation = nil
        cachedScrollView = nil
        hasNoScrollView = false
        updateTailStyle()
        updateAnimationsEnabled()
        updateFadeDuration()
        guard window != nil else {
            stopSideDeceleration()
            finishAllAnimations()
            if !WaitingTags.keepWaitingOutsideWindow(tagAnimationTiming) { showWaitingTagsAtRest() }
            stopCrossfade()
            handTailToTiles()
            releaseTiles()
            return
        }
        if let scrollView = enclosingScrollView {
            scrollObservation = scrollView.observe(\.contentOffset) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateCanvas() }
            }
            // A lazy stack moves a row when it measures the rows above it,
            // which changes the content size. The row's own frame and the
            // scroll offset stay the same, so nothing else tells the view.
            ContentSizeWatcher.watcher(for: scrollView).add(self)
        }
        updateCanvas()
        selectAllIfNeeded()
        startWaitingTagsSoon()
    }

    /// Updates the tiles on the next turn of the run loop, once the stack has
    /// placed its rows. One check is pending at a time. Only a view with some
    /// of its tiles is checked: one whose tiles cover all of it, as a short
    /// text's one tile does, is right wherever it moves, and one with none is
    /// far from the screen and updates when it is scrolled or laid out.
    fileprivate func updateCanvasSoon() {
        guard !canvasCheckScheduled, !tilesReleased, !tiles.isEmpty, !tilesCoverView else { return }
        canvasCheckScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.canvasCheckScheduled = false
                self.updateCanvas()
            }
        }
    }

    private weak var cachedScrollView: UIScrollView?
    /// The lookup found no scroll view above this view.
    private var hasNoScrollView = false

    /// The nearest scroll view above this view. Looked up once while the
    /// view stays where it is: it is needed for every frame of a scroll.
    private var enclosingScrollView: UIScrollView? {
        if let cachedScrollView { return cachedScrollView }
        if hasNoScrollView { return nil }
        var ancestor = superview
        while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
        cachedScrollView = ancestor as? UIScrollView
        hasNoScrollView = cachedScrollView == nil && window != nil
        return cachedScrollView
    }

    /// The part of this view currently on screen, or all of it outside a scroll view.
    private var visibleRect: CGRect {
        guard let scrollView = enclosingScrollView else { return bounds }
        return convert(scrollView.bounds, from: scrollView).intersection(bounds)
    }

    /// Whether the view is on screen or within half a screen of it. A view
    /// further away, such as a lazy stack's row that scrolled off, frees its tiles.
    private var isNearVisibleArea: Bool {
        guard bounds.width > 0, bounds.height > 0 else { return false }
        guard let scrollView = enclosingScrollView else { return window != nil }
        let area = scrollView.bounds.insetBy(dx: 0, dy: -scrollView.bounds.height / 2)
        return convert(area, from: scrollView).intersects(bounds)
    }

    /// Spare tiles kept for reuse beyond this many are removed.
    private let maximumSpareTiles = 4

    /// Hides a tile and keeps it for reuse. A visible view keeps the spare's
    /// drawing, so that reusing it does not allocate a new backing store.
    private func retire(_ tile: CanvasView, freeingDrawing: Bool) {
        tile.isHidden = true
        if freeingDrawing { tile.layer.contents = nil }
        spareTiles.append(tile)
    }

    /// Frees every tile's drawing, for a view with nothing on screen or near it.
    private func releaseTiles() {
        guard !tilesReleased else { return }
        tilesReleased = true
        tiles.values.forEach { retire($0, freeingDrawing: true) }
        tiles.removeAll()
        spareTiles.forEach { $0.layer.contents = nil }
        trimSpareTiles()
    }

    /// No tile holds a drawing, so releasing them again does nothing.
    private var tilesReleased = true

    private var tilesCoverView: Bool {
        guard !tilesReleased, bounds.height > 0 else { return false }
        let count = Int((bounds.height / tileHeight).rounded(.up))
        return tiles.count >= count && (0..<count).allSatisfy { tiles[$0] != nil }
    }

    private func trimSpareTiles() {
        while spareTiles.count > maximumSpareTiles {
            spareTiles.removeLast().removeFromSuperview()
        }
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
        for tile in tiles.values {
            let minY = tile.frame.minY
            let top = max(range.lowerBound - minY - 2, 0)
            let bottom = min(range.upperBound - minY + 2, tile.bounds.height)
            if top < bottom {
                tile.setNeedsDisplay(CGRect(x: 0, y: top, width: tile.bounds.width, height: bottom - top))
            }
        }
    }

    private func updateCanvas(forceRedraw: Bool = false, changed: ClosedRange<CGFloat>? = nil) {
        // Tags waiting to be on screen may be now.
        if !waiting.isEmpty, tagAnimationTiming.contains(.whenVisible) {
            visibilityCheckDelay = Self.firstVisibilityCheck
            startWaitingTagsSoon()
        }
        let visible = visibleRect
        guard !visible.isNull, visible.height > 0, bounds.width > 0 else {
            if !isNearVisibleArea {
                releaseTiles()
            } else if forceRedraw {
                tiles.values.forEach { $0.setNeedsDisplay() }
            }
            return
        }
        tilesReleased = false
        // Keep half a screen of drawn content above and below what is visible.
        let covered = visible.insetBy(dx: 0, dy: -visible.height / 2).intersection(bounds)
        let first = Int((covered.minY / tileHeight).rounded(.down))
        let last = max(Int(((covered.maxY - 0.5) / tileHeight).rounded(.down)), first)

        for (index, tile) in tiles where index < first || index > last {
            retire(tile, freeingDrawing: false)
            tiles[index] = nil
        }
        for index in first...last {
            // Wider than the view: tags' shapes may draw past the text column.
            let side = TranscriptPath.maximumSideOverhang
            let rows = TileGrid.tileFrame(at: index, viewHeight: bounds.height, glyphBottom: currentLayout.glyphBottom)
            let frame = CGRect(x: -side, y: rows.top, width: bounds.width + 2 * side, height: rows.height)
            if let tile = tiles[index] {
                if tile.frame != frame {
                    tile.frame = frame
                    tile.setNeedsDisplay()
                } else if forceRedraw {
                    if let changed {
                        let top = max(changed.lowerBound - frame.minY - 2, 0)
                        let bottom = min(changed.upperBound - frame.minY + 2, frame.height)
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
        trimSpareTiles()
    }

    /// Draws now the tiles that wait for the next commit. They take back
    /// the tail first, so that they hold all of the text.
    private func drawTilesNow() {
        handTailToTiles()
        if canvasCheckScheduled { updateCanvas() }
        for tile in tiles.values { tile.layer.displayIfNeeded() }
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
                           dark: colors.dark, highContrast: colors.highContrast, hiding: hiding, scroll: sideScroll)
    }

    private func resolvedColors() -> TailRenderer.Colors {
        let dark = traitCollection.userInterfaceStyle == .dark
        let highContrast = traitCollection.accessibilityContrast == .high
        return TailRenderer.Colors(
            text: style.textColor?.cgColor(dark: dark, highContrast: highContrast)
                ?? UIColor.label.resolvedColor(with: traitCollection).cgColor,
            codeBackground: style.codeBackgroundColor?.cgColor(dark: dark, highContrast: highContrast)
                ?? UIColor.secondarySystemFill.resolvedColor(with: traitCollection).cgColor,
            accent: style.accentColor?.cgColor(dark: dark, highContrast: highContrast)
                ?? UIColor.tertiaryLabel.resolvedColor(with: traitCollection).cgColor,
            dark: dark,
            highContrast: highContrast
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
        // With a line limit, the end of a stream is past the last line shown,
        // and a tail surface would draw it below the view.
        let enabled = window != nil && TranscriptDiagnostics.drawsTailOffMainThread && style.lineLimit == nil
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
        guard tailTop != .greatestFiniteMagnitude || tailNeedsSettling else { return }
        tailNeedsSettling = false
        engine.settleTail()
        if let band = showTail(nil) {
            updateCanvas(forceRedraw: true, changed: band)
        }
    }

    /// Hides the tail and lets the tiles draw its part, without waiting for
    /// the layout queue: the engine goes on drawing tails, and the next
    /// output shows one again.
    private func hideTail() {
        guard tailTop != .greatestFiniteMagnitude else { return }
        tailNeedsSettling = true
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
                } else if self.tailTop != .greatestFiniteMagnitude || self.tailNeedsSettling {
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
        if bounds.width == 0, unsizedWidth > 0, output.source == source, output.layout.width == unsizedWidth,
           output.layout.style == layoutStyle {
            // Not placed yet: nothing to show, but SwiftUI must hear that the height changed.
            engine.settleAnimations(output.started + output.waiting)
            if ceil(output.layout.height) != unsizedHeight { onHeightChangeWhileUnsized?() }
            return
        }
        guard output.source == source, output.layout.width == bounds.width, output.layout.style == layoutStyle else {
            if output.source < source, output.layout.width == bounds.width, output.layout.style == layoutStyle {
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
        if !isAppend { stopCrossfade() }
        install(output.layout, changedTop: isAppend ? output.changedTop : nil, tail: output.tail,
                restyled: isAppend ? output.restyled : [], started: output.started, waiting: output.waiting,
                fade: isAppend ? output.fade : nil, fadingFrom: output.hidden.fadingFrom, isFinished: output.isFinished)
        // A tail drawn while a tag was in another state than it is now (its
        // animation has started or ended since): the tiles draw that part.
        // One drawn before a block in it was last scrolled sideways: the
        // tiles draw that part until the next tail.
        if let tail = output.tail {
            if output.hidden != hiding {
                handTailToTiles()
            } else if !output.layout.scrollsAlike(output.scroll, sideScroll, below: tail.top) {
                hideTail()
            }
        }
        // Fading text drawn before its block was last scrolled sideways shows at rest.
        if output.fade != nil, !output.layout.scrollsAlike(output.scroll, sideScroll, fromOffset: output.hidden.fadingFrom ?? 0) {
            settleFades()
        }
    }

    /// Lays out synchronously, for when the view cannot wait for the
    /// background: no layout on screen yet, or a new width or style.
    ///
    /// - Parameter keepingFades: text that fades in goes on fading if the
    ///   new layout leaves it where it was: an image arrived, or a code
    ///   block's colors.
    private func relayoutNow(keepingFades: Bool = false) {
        guard bounds.width > 0,
              let result = engine.relayout(width: bounds.width, style: layoutStyle, keepingFades: keepingFades) else { return }
        skippedOutput = nil
        guard result.source == source else { return }
        install(result.layout, changedTop: nil, tail: nil, keptFadingFrom: result.fadingFrom, isFinished: result.isFinished,
                keepsAnimations: true)
    }

    private func layOutNowIfNothingIsShown() {
        if installed == nil { relayoutNow() }
    }

    /// Lays out a replaced document now (see `replacementCrossfadeDuration`),
    /// and crossfades to it from the old drawing.
    private func replaceNow(crossfade duration: TimeInterval) {
        let shown = installed
        let signpost = replacementSignposter.beginInterval("Replace document")
        relayoutNow()
        replacementSignposter.endInterval("Replace document", signpost)
        stopCrossfade()
        guard installed !== shown, duration > 0, window != nil else { return }
        // The render server fades from the canvas as the last commit showed
        // it to the canvas as this commit shows it, with the tiles that the
        // new layout draws in this commit. It is a layer animation, so
        // `UIView.performWithoutAnimation` does not stop it.
        let transition = CATransition()
        transition.type = .fade
        transition.duration = duration
        transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        let count = crossfadeCount
        transition.delegate = CrossfadeEnd { [weak self] in
            guard let self, self.crossfadeCount == count else { return }
            self.canvasClip.clipsToBounds = false
        }
        canvasClip.clipsToBounds = true
        canvas.layer.add(transition, forKey: Self.crossfadeKey)
    }

    private func stopCrossfade() {
        canvas.layer.removeAnimation(forKey: Self.crossfadeKey)
        crossfadeCount += 1
        canvasClip.clipsToBounds = false
    }

    /// Core Animation keeps a `CATransition` under this key, whatever key
    /// `add(_:forKey:)` gets.
    private static let crossfadeKey = kCATransition

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
    /// - Parameter fade: with `changedTop`, the text fading in, from
    ///   `fadingFrom` on, which the tail and the tiles leave out.
    /// - Parameter keepsAnimations: the view laid out its text again (a new
    ///   width or style, an image or code colors that arrived). Tags that
    ///   wait or play go on if the text is the one they are in.
    private func install(_ layout: DocumentLayout, changedTop: CGFloat?, tail: TailRenderer.Frame?, restyled: [CGRect] = [],
                         started: [TagKey] = [], waiting newlyWaiting: [TagKey] = [], fade: FadeFrame? = nil, fadingFrom: Int? = nil,
                         keptFadingFrom: Int? = nil, isFinished: Bool = false, keepsAnimations: Bool = false) {
        self.isFinished = isFinished
        TranscriptDiagnostics.count(\.installs)
        let old = installed
        let isAppend = changedTop != nil && old != nil
        if !isAppend { storedInputDelegate?.textWillChange(self) }
        if isAppend {
            self.fadingFrom = fadingFrom
        } else if let keptFadingFrom {
            // Laid out again with the fading text where it was: its layers stay.
            self.fadingFrom = keptFadingFrom
        } else {
            if self.fadingFrom != nil || !fadeLayers.isEmpty { _ = engine.endFades() }
            self.fadingFrom = nil
        }
        // Blocks keep their offsets while they stay, of the same kind.
        if !isAppend, !sideScroll.isEmpty, let old {
            let kept = sideScroll.kept(from: old, in: layout)
            if kept != sideScroll {
                sideScroll = kept
                engine.setSideScroll(kept)
                if let target = sidePanTarget, !SideScroll.keeps(target.id, from: old, in: layout) {
                    sidePanTarget = nil
                    releaseFades()
                }
                if let moving = sideDeceleration, !SideScroll.keeps(moving.id, from: old, in: layout) { stopSideDeceleration() }
            }
        }
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
            showFades(fade)
        } else if keptFadingFrom == nil {
            removeFades()
        }

        waiting.forgetBands()
        let firstText = animatesFirstText && layout.length > 0
        let keepsText = keepsAnimations && !isAppend && old.map { layout.document.extends($0.document) } == true
        let closed = firstText || (keepsText && !(waiting.isEmpty && playing.isEmpty)) ? layout.closedAnimatedTags() : []
        if isAppend {
            // A playing tag whose glyphs moved (its line wrapped otherwise)
            // ends where it is.
            for (key, play) in playing where layout.animatedTag(key).map({ !$0.isPlaced(like: play.tag) }) ?? true {
                finishAnimation(key)
            }
            startAnimations(started, in: layout)
            waiting.add(newlyWaiting)
            let held = WaitingTags.carried(isAppend: true, keepsText: false, firstText: firstText, closed: closed,
                                           waiting: waiting.keys, started: Set(started + newlyWaiting), playing: playingKeys) { _ in true }
            if !held.waiting.isEmpty {
                engine.holdAnimations(held.waiting)
                waiting.add(held.waiting)
            }
            startWaitingTagsSoon()
        } else {
            // Everything was drawn again, at rest, apart from the tags that
            // go on (see `WaitingTags.carried`).
            let carried = WaitingTags.carried(isAppend: false, keepsText: keepsText, firstText: firstText, closed: closed,
                                              waiting: waiting.keys, started: [], playing: playingKeys) { key in
                guard let play = playing[key], let tag = layout.animatedTag(key) else { return false }
                return tag.isPlaced(like: play.tag)
            }
            removeAllAnimations(keepingWaiting: carried.waiting, keepingPlaying: carried.playing, in: layout)
            engine.settleAnimations(started + newlyWaiting)
            if !carried.waiting.isEmpty || !carried.playing.isEmpty {
                // A relayout starts the engine's list again.
                engine.holdAnimations(carried.waiting.union(carried.playing))
                engine.playAnimations(carried.playing)
                waiting.add(carried.waiting)
                waiting.request(carried.replayed)
                startWaitingTagsSoon()
            }
        }
        if layout.length > 0 { hasShownText = true }

        if !isAppend {
            storedInputDelegate?.textDidChange(self)
            refreshSelectionDisplay()
        }
        postAccessibilityLayoutChangeIfNeeded(for: layout, isAppend: isAppend)
    }

    // MARK: Fades

    private func updateFadeDuration() {
        let enabled = window != nil && !UIAccessibility.isReduceMotionEnabled && style.lineLimit == nil && !fadesHeld
        engine.setFadeDuration(enabled ? textFadeInDuration : nil)
        if !enabled { settleFades() }
    }

    /// Puts each fade's pieces in its layers, in the same transaction as the
    /// tail and the tiles that leave the text out. A fade's layers keep the
    /// animation they started with when their pieces move.
    private func showFades(_ frame: FadeFrame?) {
        guard let frame, let duration = textFadeInDuration else {
            removeFades()
            return
        }
        var pieces: [Int: [FadeFrame.Piece]] = [:]
        for piece in frame.pieces { pieces[piece.fade, default: []].append(piece) }
        for (id, layers) in fadeLayers where pieces[id] == nil {
            layers.forEach { $0.removeFromSuperlayer() }
            fadeLayers[id] = nil
        }
        for (id, fadePieces) in pieces {
            var layers = fadeLayers[id] ?? []
            while layers.count > fadePieces.count { layers.removeLast().removeFromSuperlayer() }
            for (index, piece) in fadePieces.enumerated() {
                let layer: CALayer
                if index < layers.count {
                    layer = layers[index]
                } else {
                    layer = TagAnimationPlayer.StillLayer()
                    let animation = CABasicAnimation(keyPath: "opacity")
                    animation.fromValue = 0
                    animation.toValue = 1
                    animation.beginTime = piece.start
                    animation.duration = duration
                    animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    animation.fillMode = .backwards
                    layer.add(animation, forKey: "fade")
                    fadeLayer.addSublayer(layer)
                    layers.append(layer)
                }
                // A new image costs Core Animation a copy on this thread; an unchanged one, nothing.
                if layer.contents.map({ ($0 as AnyObject) !== piece.image }) ?? true { layer.contents = piece.image }
                if layer.contentsScale != frame.scale { layer.contentsScale = frame.scale }
                if layer.frame != piece.frame { layer.frame = piece.frame }
            }
            fadeLayers[id] = layers
            fadesEnd = max(fadesEnd, (fadePieces.first?.start ?? 0) + duration)
        }
        if !fadeLayers.isEmpty { scheduleFadeSettling() }
    }

    /// Draws the faded text at rest once the newest fade has ended and no
    /// newer text has come to fade. The engine draws it into the tail, as
    /// an update; if that does not come, the tiles draw it.
    private func scheduleFadeSettling() {
        guard !fadeSettleScheduled else { return }
        fadeSettleScheduled = true
        let delay = max(fadesEnd - CACurrentMediaTime(), 0) + 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.fadeSettleScheduled = false
                guard !self.fadeLayers.isEmpty else { return }
                let late = CACurrentMediaTime() - self.fadesEnd
                if late < 0 {
                    self.scheduleFadeSettling()
                } else if late < Self.fadeSettleGrace {
                    self.engine.settleFinishedFades()
                    self.fadeSettleScheduled = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeSettleGrace) { [weak self] in
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            self.fadeSettleScheduled = false
                            guard !self.fadeLayers.isEmpty else { return }
                            if CACurrentMediaTime() >= self.fadesEnd + Self.fadeSettleGrace {
                                self.settleFades()
                            } else {
                                self.scheduleFadeSettling()
                            }
                        }
                    }
                } else {
                    self.settleFades()
                }
            }
        }
    }

    private static let fadeSettleGrace: CFTimeInterval = 0.25

    /// Ends every fade: the tiles draw the text again, in the same
    /// transaction as the fade layers go.
    private func settleFades() {
        let from = engine.endFades() ?? fadingFrom
        fadingFrom = nil
        if let from, let layout = installed {
            let top = layout.caretRect(at: min(from, layout.length)).minY - 8
            let band = top...max(top, layout.height + TranscriptPath.maximumOverhang)
            // The tail was drawn without the fading text.
            if tailTop < band.upperBound { handTailToTiles() }
            redrawTiles(in: band)
        }
        removeFades()
    }

    private func removeFades() {
        for layers in fadeLayers.values { layers.forEach { $0.removeFromSuperlayer() } }
        fadeLayers.removeAll()
    }

    // MARK: Tag animations

    @objc private func reduceMotionChanged() {
        updateAnimationsEnabled()
        updateFadeDuration()
    }

    /// Whether tags can animate at all: on, and Reduce Motion off.
    private var animationsCanPlay: Bool { animatesTags && !UIAccessibility.isReduceMotionEnabled }

    /// Whether the first text's closed tags wait to play.
    private var animatesFirstText: Bool { animatesTagsInFirstText && !hasShownText && animationsCanPlay }

    /// Tells the engine whether tags that close start or wait. Outside a
    /// window, only tags that wait to be seen or for the app wait; others
    /// are drawn as they end up. Leaving the window is handled in
    /// `didMoveToWindow`.
    private func updateAnimationsEnabled() {
        if animatesTags, window != nil, UIAccessibility.isReduceMotionEnabled {
            animationLog.debug("Tags are not animated: Reduce Motion is on")
        }
        let enabled = animationsCanPlay && (window != nil || WaitingTags.keepWaitingOutsideWindow(tagAnimationTiming))
        engine.setAnimationsEnabled(enabled, immediately: tagAnimationTiming == .immediately)
        if !animationsCanPlay {
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
        let looks = timing.contains(.whenVisible) && window != nil
        let viewer = WaitingTags.Viewer(isInWindow: window != nil, isHidden: looks && isHiddenInWindow,
                                        visibleRect: looks ? visibleRect : .null, isFinished: isFinished)
        let ready = waiting.takeReady(timing: timing, viewer: viewer) { layout.animatedTag($0)?.band }
        if waiting.waitForHiddenView(timing: timing, viewer: viewer) {
            checkVisibilityLater()
        } else {
            visibilityCheckDelay = Self.firstVisibilityCheck
        }
        guard !ready.isEmpty else { return }
        engine.playAnimations(ready)
        startAnimations(ready, in: layout, wereWaiting: true)
    }

    /// Whether this view or an ancestor is hidden or has an alpha of 0. The
    /// layers are read, so that a layer above the view that no view owns
    /// counts too.
    private var isHiddenInWindow: Bool {
        WaitingTags.isHidden(sequence(first: layer, next: \.superlayer).lazy.map { ($0.isHidden, CGFloat($0.opacity)) })
    }

    /// Looks again in a moment whether tags that wait for a hidden view can
    /// play: no call tells the view when an ancestor shows again. Each look
    /// while the view stays hidden comes later than the one before, up to
    /// one second apart.
    private func checkVisibilityLater() {
        guard !visibilityCheckScheduled else { return }
        visibilityCheckScheduled = true
        let delay = visibilityCheckDelay
        visibilityCheckDelay = min(delay * 2, Self.lastVisibilityCheck)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.visibilityCheckScheduled = false
                self.startWaitingTags()
            }
        }
    }

    /// Draws every waiting tag as it ends up, shapes and all, for when it
    /// can no longer play.
    private func showWaitingTagsAtRest() {
        guard !waiting.isEmpty else { return }
        let keys = waiting.removeAll()
        engine.settleAnimations(keys)
        for key in keys {
            guard let tag = installed?.animatedTag(key) else { continue }
            let band = band(of: tag)
            // The tail was drawn without the tag's shapes.
            if tailTop < band.upperBound { handTailToTiles() }
            redrawTiles(in: band)
        }
    }

    /// Plays the animations of `keys`, which start together, over the text,
    /// which from now on leaves them out.
    ///
    /// - Parameter wereWaiting: they waited for their timing, and the tail,
    ///   drawn when they were waiting, still shows their glyphs.
    private func startAnimations(_ keys: [TagKey], in layout: DocumentLayout, wereWaiting: Bool = false) {
        guard !keys.isEmpty else { return }
        let batch = layout.tagsStartingTogether(keys)
        if batch.count < keys.count {
            let found = Set(batch.map(\.tag.key))
            engine.settleAnimations(keys.filter { !found.contains($0) })
        }
        for (tag, group) in batch {
            startAnimation(tag, in: group, wasWaiting: wereWaiting, layout: layout)
        }
    }

    private func startAnimation(_ tag: AnimatedTag, in group: TranscriptAnimationGroup, wasWaiting: Bool, layout: DocumentLayout) {
        let key = tag.key
        if playing[key] != nil { finishAnimation(key) }
        // Its layers could not follow the block's offset: the tag shows at rest.
        if sidePan != nil, let index = layout.entryIndex(ofBlock: key.block), layout.entry(at: index).layout.maximumScrollOffset > 0 {
            engine.settleAnimations([key])
            if tailTop < band(of: tag).upperBound { handTailToTiles() }
            redrawTiles(in: band(of: tag))
            return
        }
        if wasWaiting, tailTop < band(of: tag).upperBound { handTailToTiles() }
        let animation = tag.animation.animation(for: tag.fragments, in: group)
        let colors = resolvedColors()
        let scale = traitCollection.displayScale
        let sprites = TagAnimationPlayer.sprites(for: tag, animation: animation,
                                                 appearance: .init(text: colors.text, dark: colors.dark,
                                                                   highContrast: colors.highContrast, scale: scale))
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
    /// being drawn again anyway, apart from the waiting tags in `keptWaiting`
    /// and the playing tags in `keptPlaying`, which `layout` places where
    /// they were.
    private func removeAllAnimations(keepingWaiting keptWaiting: Set<TagKey>, keepingPlaying keptPlaying: Set<TagKey>,
                                     in layout: DocumentLayout) {
        engine.settleAnimations(waiting.keys.subtracting(keptWaiting))
        waiting.keep(keptWaiting)
        guard !playing.isEmpty else { return }
        engine.settleAnimations(playingKeys)
        for (key, play) in playing {
            if keptPlaying.contains(key), let tag = layout.animatedTag(key) {
                playing[key] = PlayingTag(tag: tag, layer: play.layer, start: play.start, signpost: play.signpost)
                continue
            }
            play.layer.removeFromSuperlayer()
            animationSignposter.endInterval("Tag animation", play.signpost)
            playing[key] = nil
            playingKeys.remove(key)
        }
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
        let clip = bounds.insetBy(dx: -TranscriptPath.maximumSideOverhang, dy: -TranscriptPath.maximumOverhang)
        canvasClip.frame = clip
        canvasClip.bounds = clip
        canvas.frame = bounds
        animationLayer.frame = canvas.bounds
        fadeLayer.frame = canvas.bounds
        if bounds.width > 0 { unsizedWidth = 0 }
        if bounds.width > 0, installed?.width != bounds.width || installed?.style != layoutStyle {
            relayoutNow()
            refreshSelectionDisplay()
        }
        updateCanvas()
    }

    /// Called when the text's height changes while the view has no width of
    /// its own, measured at the width of the last `sizeThatFits`. A lazy
    /// stack measures a row of zero height but does not place it, so the
    /// view never lays out and `invalidateIntrinsicContentSize` reaches nobody;
    /// `TranscriptText` asks SwiftUI to measure again instead.
    var onHeightChangeWhileUnsized: (() -> Void)?
    /// The width and height of the last `sizeThatFits` while the view had no width.
    private var unsizedWidth: CGFloat = 0
    private var unsizedHeight: CGFloat = -1

    public override func sizeThatFits(_ size: CGSize) -> CGSize {
        let width = size.width.isFinite && size.width > 0 ? size.width : max(bounds.width, 1)
        if let installed, installed.width == width, installed.style == layoutStyle {
            return CGSize(width: width, height: ceil(installed.height))
        }
        // Kept by the engine, so the relayout when the view takes this width is free.
        let height = ceil(engine.measure(width: width, style: layoutStyle))
        if bounds.width == 0, onHeightChangeWhileUnsized != nil, size.width.isFinite, size.width > 0 {
            unsizedWidth = width
            unsizedHeight = height
            engine.layOutUntilPlaced(width: width, style: layoutStyle)
        }
        return CGSize(width: width, height: height)
    }

    public override var intrinsicContentSize: CGSize {
        guard let installed else { return CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric) }
        return CGSize(width: UIView.noIntrinsicMetric, height: ceil(installed.height))
    }

    // MARK: Accessibility

    /// The elements, made when an assistive technology first asks for them.
    var accessibilityCache: AccessibilityCache?

    /// Brings the elements up to date with the layout on screen, for an
    /// element that an assistive technology kept from an earlier request.
    func updateAccessibilityElements() {
        guard accessibilityCache != nil else { return }
        _ = accessibilityElements(for: currentLayout)
    }

    /// A container: VoiceOver reads its blocks (see `accessibilityElements(for:)`).
    nonisolated public override var isAccessibilityElement: Bool {
        get { false }
        set {}
    }

    /// Any thread: assistive technologies can ask from another one (see `onMainThread`).
    nonisolated public override var accessibilityElements: [Any]? {
        get { onMainThread { accessibilityElements(for: currentLayout) } }
        set {}
    }

    // MARK: Responder

    // The responder and hit test overrides below are `nonisolated` for the
    // same reason as the `UITextInput` methods: assistive technologies can
    // reach them from another thread (see `onMainThread`).

    nonisolated public override var canBecomeFirstResponder: Bool { onMainThread { isSelectable } }

    private static let didBecomeFirstResponder = Notification.Name("TranscriptTextViewDidBecomeFirstResponder")

    /// Ends the selection of the other views in the window. This is not done
    /// in `resignFirstResponder()`: Share and Translate in the edit menu make
    /// the view resign, and the selection must stay for them.
    @discardableResult
    public override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { NotificationCenter.default.post(name: Self.didBecomeFirstResponder, object: self) }
        return became
    }

    @objc private func otherViewBecameFirstResponder(_ notification: Notification) {
        guard let other = notification.object as? TranscriptTextView, other !== self,
              other.window === window, selection != nil else { return }
        select(nil)
    }

    /// Without selection, only links take touches.
    nonisolated public override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        onMainThread {
            guard super.point(inside: point, with: event) else { return false }
            // Hit testing comes before the touch begins, and the touch's gesture
            // recognizers are gathered after it, so ones added now see it.
            if isSelectable { addTextInteractionIfNeeded() }
            return isSelectable || linkURL(at: point) != nil || (sidePan != nil && currentLayout.sideScrollingEntryIndex(at: point) != nil)
        }
    }

    private func addTextInteractionIfNeeded() {
        guard isSelectable, textInteraction == nil else { return }
        let interaction = UITextInteraction(for: .nonEditable)
        interaction.textInput = self
        addInteraction(interaction)
        textInteraction = interaction
    }

    /// Read-only: an empty input view keeps the keyboard from appearing.
    nonisolated public override var inputView: UIView? { onMainThread { emptyInputView } }

    /// Whether the edit menu offers Writing Tools for the selected text, on
    /// devices that have them. On by default, as in a `UITextView`.
    public var showsWritingTools = true

    @available(iOS 18.0, *)
    nonisolated public var writingToolsBehavior: UIWritingToolsBehavior {
        get { onMainThread { showsWritingTools ? .default : .none } }
        set { onMainThread { showsWritingTools = newValue != .none } }
    }

    nonisolated public override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        // The sender only goes on to `super`, on the main thread.
        nonisolated(unsafe) let sender = sender
        return onMainThread {
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
    }

    nonisolated public override func copy(_ sender: Any?) {
        onMainThread {
            guard let range = selectedRange else { return }
            UIPasteboard.general.string = shownDocument.copyText(in: range)
        }
    }

    nonisolated public override func selectAll(_ sender: Any?) {
        onMainThread { select(0..<currentLayout.length) }
    }

    /// Selects a range of the document's flat UTF-16 offset space, or clears
    /// the selection when `range` is nil.
    public func select(_ range: Range<Int>?) {
        if range != nil { addTextInteractionIfNeeded() }
        storedInputDelegate?.selectionWillChange(self)
        selection = range.map { clamp($0.lowerBound)..<clamp($0.upperBound) }
        storedInputDelegate?.selectionDidChange(self)
        refreshSelectionDisplay()
    }

    /// The currently selected text, if any: the text of `selectedRange`.
    public var selectedText: String? {
        selectedRange.map { shownDocument.text(in: $0) }
    }

    // MARK: UITextInput — positions and ranges

    // Every `UITextInput` method is `nonisolated` and does its work on the
    // main thread, because assistive technologies and the tokenizer can
    // call it from another thread (see `onMainThread`).

    private func offset(of position: UITextPosition) -> Int {
        (position as? TranscriptTextPosition)?.offset ?? 0
    }

    private func range(of textRange: UITextRange) -> Range<Int> {
        (textRange as? TranscriptTextRange)?.range ?? 0..<0
    }

    private func clamp(_ offset: Int) -> Int {
        min(max(offset, 0), currentLayout.length)
    }

    nonisolated public var beginningOfDocument: UITextPosition { onMainThread { TranscriptTextPosition(offset: 0) } }
    nonisolated public var endOfDocument: UITextPosition { onMainThread { TranscriptTextPosition(offset: currentLayout.length) } }

    nonisolated public func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        onMainThread {
            let a = clamp(offset(of: fromPosition))
            let b = clamp(offset(of: toPosition))
            return TranscriptTextRange(range: min(a, b)..<max(a, b))
        }
    }

    nonisolated public func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        onMainThread {
            let target = self.offset(of: position) + offset
            guard target >= 0, target <= currentLayout.length else { return nil }
            return TranscriptTextPosition(offset: target)
        }
    }

    nonisolated public func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        onMainThread {
            let start = self.offset(of: position)
            switch direction {
            case .left, .right:
                return TranscriptTextPosition(offset: currentLayout.offset(from: clamp(start), movingRight: direction == .right, by: offset))
            case .up, .down:
                let caret = currentLayout.caretRect(at: start, scroll: sideScroll)
                let step = caret.height * CGFloat(offset) * (direction == .up ? -1 : 1)
                let target = currentLayout.closestOffset(to: CGPoint(x: caret.midX, y: caret.midY + step), scroll: sideScroll)
                return TranscriptTextPosition(offset: target)
            @unknown default: return nil
            }
        }
    }

    nonisolated public func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        let a = TranscriptTextPosition.offset(of: position)
        let b = TranscriptTextPosition.offset(of: other)
        return a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }

    nonisolated public func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        TranscriptTextPosition.offset(of: toPosition) - TranscriptTextPosition.offset(of: from)
    }

    nonisolated public func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        onMainThread {
            let range = self.range(of: range)
            switch direction {
            case .left, .right:
                return TranscriptTextPosition(offset: currentLayout.farthestOffset(in: range, right: direction == .right))
            case .up: return TranscriptTextPosition(offset: range.lowerBound)
            case .down: return TranscriptTextPosition(offset: range.upperBound)
            @unknown default: return nil
            }
        }
    }

    nonisolated public func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        onMainThread {
            let start = offset(of: position)
            switch direction {
            case .left, .right:
                let end = currentLayout.offset(from: clamp(start), movingRight: direction == .right)
                return TranscriptTextRange(range: min(start, end)..<max(start, end))
            case .up: return TranscriptTextRange(range: clamp(start - 1)..<start)
            case .down: return TranscriptTextRange(range: start..<clamp(start + 1))
            @unknown default: return nil
            }
        }
    }

    // MARK: UITextInput — text and selection

    nonisolated public func text(in range: UITextRange) -> String? {
        onMainThread { shownDocument.text(in: self.range(of: range)) }
    }

    nonisolated public var selectedTextRange: UITextRange? {
        get { onMainThread { selection.map { TranscriptTextRange(range: $0) } } }
        set { onMainThread { selection = newValue.map { range(of: $0) } } }
    }

    private weak var storedInputDelegate: UITextInputDelegate?

    nonisolated public var inputDelegate: UITextInputDelegate? {
        get { onMainThread { storedInputDelegate } }
        set {
            // Only the main thread uses the delegate once it is stored.
            nonisolated(unsafe) let delegate = newValue
            onMainThread { storedInputDelegate = delegate }
        }
    }

    private lazy var storedTokenizer: UITextInputTokenizer = UITextInputStringTokenizer(textInput: self)

    nonisolated public var tokenizer: UITextInputTokenizer { onMainThread { storedTokenizer } }

    // MARK: UITextInput — geometry

    nonisolated public func caretRect(for position: UITextPosition) -> CGRect {
        onMainThread { currentLayout.caretRect(at: clamp(offset(of: position)), scroll: sideScroll) }
    }

    nonisolated public func firstRect(for range: UITextRange) -> CGRect {
        onMainThread {
            let range = self.range(of: range)
            return currentLayout.firstLineRect(for: range, scroll: sideScroll)
                ?? currentLayout.caretRect(at: range.lowerBound, scroll: sideScroll)
        }
    }

    nonisolated public func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        onMainThread {
            currentLayout.selectionSegments(for: self.range(of: range), scroll: sideScroll).map { segment in
                TranscriptSelectionRect(rect: segment.rect, writingDirection: segment.isRightToLeft ? .rightToLeft : .leftToRight,
                                        containsStart: segment.containsStart, containsEnd: segment.containsEnd)
            }
        }
    }

    nonisolated public func closestPosition(to point: CGPoint) -> UITextPosition? {
        onMainThread { TranscriptTextPosition(offset: currentLayout.closestOffset(to: point, scroll: sideScroll)) }
    }

    nonisolated public func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
        onMainThread {
            let range = self.range(of: range)
            let offset = currentLayout.closestOffset(to: point, scroll: sideScroll)
            return TranscriptTextPosition(offset: min(max(offset, range.lowerBound), range.upperBound))
        }
    }

    nonisolated public func characterRange(at point: CGPoint) -> UITextRange? {
        onMainThread {
            let offset = currentLayout.closestOffset(to: point, scroll: sideScroll)
            guard offset < currentLayout.length else { return nil }
            return TranscriptTextRange(range: offset..<(offset + 1))
        }
    }

    nonisolated public func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection {
        onMainThread {
            currentLayout.isRightToLeft(at: clamp(offset(of: position)), backward: direction == .backward) ? .rightToLeft : .leftToRight
        }
    }

    nonisolated public func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}

    // MARK: UITextInput — editing (unsupported: the view is read-only)

    nonisolated public var hasText: Bool { onMainThread { currentLayout.length > 0 } }
    nonisolated public func insertText(_ text: String) {}
    nonisolated public func deleteBackward() {}
    nonisolated public func replace(_ range: UITextRange, withText text: String) {}
    nonisolated public var markedTextRange: UITextRange? { nil }
    nonisolated public var markedTextStyle: [NSAttributedString.Key: Any]? {
        get { nil }
        set {}
    }
    nonisolated public func setMarkedText(_ markedText: String?, selectedRange: NSRange) {}
    nonisolated public func unmarkText() {}
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

/// Calls the view on each display frame while a block moves on after a
/// pan. The display link keeps its target, so this keeps the view weakly.
@MainActor
private final class SideScrollFrameTarget: NSObject {
    weak var view: TranscriptTextView?

    init(view: TranscriptTextView) {
        self.view = view
    }

    @objc func frame(_ link: CADisplayLink) {
        guard let view else {
            link.invalidate()
            return
        }
        view.stepSideDeceleration(link)
    }
}

/// Runs an action when a crossfade ends or is removed.
@MainActor
private final class CrossfadeEnd: NSObject, CAAnimationDelegate {
    private let action: @MainActor () -> Void

    init(_ action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    nonisolated func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        MainActor.assumeIsolated { action() }
    }
}

// MARK: - Position, range and selection rect types

// These never change once made, so their getters are `nonisolated`: the
// system can read them on any thread.

final class TranscriptTextPosition: UITextPosition {
    nonisolated let offset: Int

    init(offset: Int) {
        self.offset = offset
        super.init()
    }

    nonisolated static func offset(of position: UITextPosition) -> Int {
        (position as? TranscriptTextPosition)?.offset ?? 0
    }
}

final class TranscriptTextRange: UITextRange {
    nonisolated let range: Range<Int>
    private nonisolated let startPosition: TranscriptTextPosition
    private nonisolated let endPosition: TranscriptTextPosition

    init(range: Range<Int>) {
        self.range = range
        startPosition = TranscriptTextPosition(offset: range.lowerBound)
        endPosition = TranscriptTextPosition(offset: range.upperBound)
        super.init()
    }

    nonisolated override var start: UITextPosition { startPosition }
    nonisolated override var end: UITextPosition { endPosition }
    nonisolated override var isEmpty: Bool { range.isEmpty }
}

final class TranscriptSelectionRect: UITextSelectionRect {
    private nonisolated let storedRect: CGRect
    private nonisolated let storedWritingDirection: NSWritingDirection
    private nonisolated let storedContainsStart: Bool
    private nonisolated let storedContainsEnd: Bool

    init(rect: CGRect, writingDirection: NSWritingDirection, containsStart: Bool, containsEnd: Bool) {
        storedRect = rect
        storedWritingDirection = writingDirection
        storedContainsStart = containsStart
        storedContainsEnd = containsEnd
        super.init()
    }

    nonisolated override var rect: CGRect { storedRect }
    nonisolated override var writingDirection: NSWritingDirection { storedWritingDirection }
    nonisolated override var containsStart: Bool { storedContainsStart }
    nonisolated override var containsEnd: Bool { storedContainsEnd }
    nonisolated override var isVertical: Bool { false }
}

/// Watches a scroll view's content size for the text views in it, with one
/// observation for all of them: a list can hold many.
@MainActor
private final class ContentSizeWatcher {
    private static var key: UInt8 = 0
    private var observation: NSKeyValueObservation?
    private let views = NSHashTable<TranscriptTextView>.weakObjects()

    /// The scroll view's watcher, which the scroll view keeps.
    static func watcher(for scrollView: UIScrollView) -> ContentSizeWatcher {
        if let watcher = objc_getAssociatedObject(scrollView, &key) as? ContentSizeWatcher { return watcher }
        let watcher = ContentSizeWatcher()
        watcher.observation = scrollView.observe(\.contentSize) { [weak watcher] _, _ in
            MainActor.assumeIsolated { watcher?.contentSizeChanged() }
        }
        objc_setAssociatedObject(scrollView, &key, watcher, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return watcher
    }

    func add(_ view: TranscriptTextView) {
        views.add(view)
    }

    private func contentSizeChanged() {
        for view in views.allObjects where view.window != nil {
            view.updateCanvasSoon()
        }
    }
}
#endif
