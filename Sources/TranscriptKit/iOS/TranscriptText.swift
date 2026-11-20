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
/// update (layout still happens in the background).
public struct TranscriptText: UIViewRepresentable {
    private enum Source {
        case document(TranscriptDocument)
        case stream(TranscriptStream)
    }

    private let source: Source
    private let style: TranscriptStyle
    private var loader: (@Sendable (TranscriptImage) async -> CGImage?)?
    private var animatesTags = true
    private var animationTiming: TranscriptAnimationTiming = .immediately
    private var isSelectable = true
    private var playTrigger: AnyHashable?
    private var selectionChange: ((Range<Int>?) -> Void)?
    private var selectsAll = false

    public init(_ document: TranscriptDocument, style: TranscriptStyle = .init()) {
        self.source = .document(document)
        self.style = style
    }

    public init(stream: TranscriptStream, style: TranscriptStyle = .init()) {
        self.source = .stream(stream)
        self.style = style
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

    /// Whether custom tags with an animation play it when they finish
    /// arriving; see `TranscriptTextView.animatesTags`. On by default.
    public func animatesTags(_ animates: Bool) -> TranscriptText {
        var copy = self
        copy.animatesTags = animates
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
        return view
    }

    public func updateUIView(_ view: TranscriptTextView, context: Context) {
        view.style = style
        view.animatesTags = animatesTags
        view.tagAnimationTiming = animationTiming
        view.isSelectable = isSelectable
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
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, uiView: TranscriptTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }
}
#endif
