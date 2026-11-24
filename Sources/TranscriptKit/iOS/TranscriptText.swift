#if canImport(UIKit) && !os(watchOS)
import SwiftUI
import UIKit

/// SwiftUI wrapper for `TranscriptTextView`. It sizes itself to the proposed
/// width, so place it in a vertical `ScrollView`.
///
/// For streamed text, prefer `init(stream:)`: each frame's chunks are parsed
/// and laid out in the background and go straight to the view, and SwiftUI
/// only re-measures the view when its height changes. With
/// `init(_ document:)`, every new document goes through a full SwiftUI
/// update (layout still happens in the background, unless
/// `crossfadesReplacedText(_:duration:)` lays out a replaced one at once).
public struct TranscriptText: UIViewRepresentable {
    private enum Source {
        case document(TranscriptDocument)
        case stream(TranscriptStream)
    }

    private let source: Source
    private let style: TranscriptStyle
    private var loader: (@Sendable (TranscriptImage) async -> CGImage?)?
    private var highlighter: TranscriptCodeHighlighter?
    private var mathRenderer: TranscriptMathRenderer?
    private var mathCache: TranscriptMathCache = .shared
    private var mathAccessibilityLabel: ((TranscriptMath) -> String)?
    private var animatesTags = true
    private var textFadeInDuration: TimeInterval?
    private var replacementCrossfadeDuration: TimeInterval?
    private var animationTiming: TranscriptAnimationTiming = .immediately
    private var animatesFirstText = false
    private var isSelectable = true
    private var playTrigger: AnyHashable?
    private var selectionChange: ((Range<Int>?) -> Void)?
    private var selectsAll = false
    private var showsWritingTools = true
    /// Changed when the view's height changes before SwiftUI has placed it,
    /// so that SwiftUI measures the view again (see
    /// `TranscriptTextView.onHeightChangeWhileUnsized`).
    @State private var unsizedRevision = 0
    /// The stream's `unplacedHeight` revision when this was made.
    private var unplacedHeightRevision = 0

    public init(_ document: TranscriptDocument, style: TranscriptStyle = .init()) {
        self.source = .document(document)
        self.style = style
    }

    public init(stream: TranscriptStream, style: TranscriptStyle = .init()) {
        self.source = .stream(stream)
        self.style = style
        // A lazy stack can leave a new row unplaced and then ignore the
        // row's own state, so `unsizedRevision` does not reach it. Read
        // here, the revision is a dependency of the view whose body makes
        // this one: when it changes, that body runs again, this value
        // differs, and SwiftUI updates and measures the row.
        self.unplacedHeightRevision = stream.unplacedHeight.revision
    }

    /// Loads the pictures for images in the text; see
    /// `TranscriptTextView.imageLoader`. Without one, images show their alt
    /// text and nothing is fetched. Read once, when the view is created.
    public func imageLoader(_ loader: @escaping @Sendable (TranscriptImage) async -> CGImage?) -> TranscriptText {
        var copy = self
        copy.loader = loader
        return copy
    }

    /// Whether the text can be selected; see `TranscriptTextView.isSelectable`.
    /// On by default. Turn it off for text inside a view that reacts to taps,
    /// such as a card or a list row: taps that are not on a link then reach it.
    public func selectable(_ selectable: Bool) -> TranscriptText {
        var copy = self
        copy.isSelectable = selectable
        return copy
    }

    /// Colors the code in code blocks; see `TranscriptTextView.codeHighlighter`.
    /// Read once, when the view is created.
    public func codeHighlighter(_ highlighter: @escaping TranscriptCodeHighlighter) -> TranscriptText {
        var copy = self
        copy.highlighter = highlighter
        return copy
    }

    /// Draws LaTeX formulas; see `TranscriptTextView.mathRenderer`. The
    /// drawn formulas are kept in `cache`, which is `TranscriptMathCache.shared`
    /// by default: views that share a cache show the formulas that any of
    /// their renderers drew. See `TranscriptTextView.mathCache`. Read once,
    /// when the view is created.
    public func mathRenderer(_ renderer: @escaping TranscriptMathRenderer, cache: TranscriptMathCache = .shared) -> TranscriptText {
        var copy = self
        copy.mathRenderer = renderer
        copy.mathCache = cache
        return copy
    }

    /// The words that VoiceOver says for a formula; see
    /// `TranscriptTextView.mathAccessibilityLabel`. Read once, when the view
    /// is created.
    public func mathAccessibilityLabel(_ label: @escaping (TranscriptMath) -> String) -> TranscriptText {
        var copy = self
        copy.mathAccessibilityLabel = label
        return copy
    }

    /// Fades in text as it streams in; see `TranscriptTextView.textFadeInDuration`.
    public func fadesInText(_ fades: Bool = true, duration: TimeInterval = 0.3) -> TranscriptText {
        var copy = self
        copy.textFadeInDuration = fades ? duration : nil
        return copy
    }

    /// Lays out a document that replaces the one before at once, so that
    /// SwiftUI gets its new height in the same update, and crossfades from
    /// the old text to the new one; see
    /// `TranscriptTextView.replacementCrossfadeDuration`. A document that
    /// only adds text to the one before is laid out in the background, as
    /// before. That includes a text that starts with the old one, parsed
    /// with the same `idPrefix`, and the first text after an empty
    /// document. Off by default.
    ///
    /// ```swift
    /// TranscriptText(showsSummary ? summary : details)
    ///     .crossfadesReplacedText(duration: 0.25)
    /// ```
    public func crossfadesReplacedText(_ crossfades: Bool = true, duration: TimeInterval = 0.25) -> TranscriptText {
        var copy = self
        copy.replacementCrossfadeDuration = crossfades ? duration : nil
        return copy
    }

    /// Whether custom tags with an animation play it when they finish
    /// arriving; see `TranscriptTextView.animatesTags`. On by default.
    public func animatesTags(_ animates: Bool) -> TranscriptText {
        var copy = self
        copy.animatesTags = animates
        return copy
    }

    /// Whether the tags with an animation that the first text already holds
    /// play it, each one time; see `TranscriptTextView.animatesTagsInFirstText`.
    /// Off by default.
    public func animatesTagsInFirstText(_ animates: Bool = true) -> TranscriptText {
        var copy = self
        copy.animatesFirstText = animates
        return copy
    }

    /// When tags' animations play once their closing tag has arrived; see
    /// `TranscriptAnimationTiming`. Right away by default.
    public func tagAnimationTiming(_ timing: TranscriptAnimationTiming) -> TranscriptText {
        var copy = self
        copy.animationTiming = timing
        return copy
    }

    /// With a timing that includes `.whenRequested`: each time `trigger`
    /// changes, the tags waiting to animate play
    /// (`TranscriptTextView.playTagAnimations()`).
    ///
    /// ```swift
    /// TranscriptText(stream: stream)
    ///     .tagAnimationTiming(.whenRequested)
    ///     .playTagAnimations(trigger: highlightsShown)
    /// ```
    public func playTagAnimations(trigger: some Hashable) -> TranscriptText {
        var copy = self
        copy.playTrigger = AnyHashable(trigger)
        return copy
    }

    /// Called after the selection changes, with the selected range of the
    /// document's flat UTF-16 offset space, or nil when nothing is selected
    /// any more. `document.text(in:)` gives the selected text. See
    /// `TranscriptTextView.onSelectionChange`.
    public func onSelectionChange(_ action: @escaping (Range<Int>?) -> Void) -> TranscriptText {
        var copy = self
        copy.selectionChange = action
        return copy
    }

    /// Selects all of the text, with the selection handles shown, when the
    /// view comes on screen; see `TranscriptTextView.selectsAllWhenShown`.
    public func selectsAllWhenShown(_ selects: Bool = true) -> TranscriptText {
        var copy = self
        copy.selectsAll = selects
        return copy
    }

    /// Whether the edit menu offers Writing Tools; see
    /// `TranscriptTextView.showsWritingTools`. On by default.
    public func showsWritingTools(_ shows: Bool) -> TranscriptText {
        var copy = self
        copy.showsWritingTools = shows
        return copy
    }

    public final class Coordinator {
        var playTrigger: AnyHashable?
    }

    public func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        coordinator.playTrigger = playTrigger
        return coordinator
    }

    public func makeUIView(context: Context) -> TranscriptTextView {
        let view = TranscriptTextView()
        view.setContentHuggingPriority(.required, for: .vertical)
        if let loader { view.imageLoader = loader }
        if let highlighter { view.codeHighlighter = highlighter }
        if let mathRenderer {
            view.mathCache = mathCache
            view.mathRenderer = mathRenderer
        }
        if let mathAccessibilityLabel { view.mathAccessibilityLabel = mathAccessibilityLabel }
        return view
    }

    public func updateUIView(_ view: TranscriptTextView, context: Context) {
        var style = style.scalesWithDynamicType
            ? style.scaled(for: UIContentSizeCategory(context.environment.dynamicTypeSize))
            : style
        // SwiftUI's `.lineLimit(_:)` and `.multilineTextAlignment(_:)` win over the style's.
        if let limit = context.environment.lineLimit { style.lineLimit = limit }
        switch context.environment.multilineTextAlignment {
        case .center: style.textAlignment = .center
        case .trailing: style.textAlignment = .trailing
        case .leading: break
        }
        view.style = style
        view.animatesTags = animatesTags
        view.animatesTagsInFirstText = animatesFirstText
        view.textFadeInDuration = textFadeInDuration
        view.replacementCrossfadeDuration = replacementCrossfadeDuration
        view.tagAnimationTiming = animationTiming
        view.isSelectable = isSelectable
        view.showsWritingTools = showsWritingTools
        if playTrigger != context.coordinator.playTrigger {
            context.coordinator.playTrigger = playTrigger
            view.playTagAnimations()
        }
        switch source {
        case .document(let document): view.document = document
        case .stream(let stream): view.stream = stream
        }
        // Links go through SwiftUI's `openURL`, so apps can intercept them
        // with the `.environment(\.openURL, ...)` modifier.
        let openURL = context.environment.openURL
        view.openLink = { openURL($0) }
        view.onSelectionChange = selectionChange
        view.selectsAllWhenShown = selectsAll
        // SwiftUI updates and measures the view again for a state change
        // only if the update reads that state.
        _ = unsizedRevision
        let revision = $unsizedRevision
        let unplacedHeight: UnplacedHeightSignal?
        if case .stream(let stream) = source { unplacedHeight = stream.unplacedHeight } else { unplacedHeight = nil }
        view.onHeightChangeWhileUnsized = {
            revision.wrappedValue &+= 1
            unplacedHeight?.revision &+= 1
        }
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, uiView: TranscriptTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }
}
#endif
