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

    public func makeUIView(context: Context) -> TranscriptTextView {
        let view = TranscriptTextView()
        view.setContentHuggingPriority(.required, for: .vertical)
        if let loader { view.imageLoader = loader }
        return view
    }

    public func updateUIView(_ view: TranscriptTextView, context: Context) {
        view.style = style
        switch source {
        case .document(let document): view.document = document
        case .stream(let stream): view.stream = stream
        }
        // Links go through SwiftUI's `openURL`, so apps can intercept them
        // with the `.environment(\.openURL, ...)` modifier.
        let openURL = context.environment.openURL
        view.openLink = { openURL($0) }
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, uiView: TranscriptTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }
}
#endif
