#if canImport(UIKit) && !os(watchOS)
import SwiftUI
import Testing
import UIKit
@testable import TranscriptKit

private let longParagraph = String(repeating: "Words that wrap onto several lines. ", count: 8)

@MainActor
private func textViews(in view: UIView) -> [TranscriptTextView] {
    view.subviews.flatMap { subview in
        (subview as? TranscriptTextView).map { [$0] } ?? textViews(in: subview)
    }
}

/// The views that SwiftUI has placed: they have a width.
@MainActor
private func placedTextViews(in root: UIView) -> [TranscriptTextView] {
    root.layoutIfNeeded()
    return textViews(in: root).filter { $0.bounds.width > 0 }
}

/// Lays out `root` until `condition` holds, for at most two seconds.
@MainActor
private func waitUntil(_ root: UIView, _ condition: () -> Bool) async {
    for _ in 0..<200 {
        root.layoutIfNeeded()
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
private func fittingHeight(of view: TranscriptTextView) -> CGFloat {
    view.sizeThatFits(CGSize(width: view.bounds.width, height: CGFloat.greatestFiniteMagnitude)).height
}

@MainActor
private func isAsTallAsItsText(_ view: TranscriptTextView) -> Bool {
    view.bounds.height == fittingHeight(of: view)
}

@Suite(.serialized) @MainActor
struct TranscriptTextTests {
    /// A window of a fixed size, so that no test depends on the screen. Each
    /// test has its own, and it lasts as long as the test.
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))

    /// Shows `content` in the window, and returns the view that holds it.
    private func show(_ content: some View) -> UIView {
        let controller = UIHostingController(rootView: content)
        window.rootViewController = controller
        window.isHidden = false
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        return controller.view
    }

    @Test func rowsInALazyStackAreAsTallAsTheirText() async throws {
        let messages = (0..<100).map { "Message \($0). " + String(repeating: "More words that wrap. ", count: $0 % 7) }
        let root = show(ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(messages, id: \.self) { TranscriptText(MarkdownStreamParser.document(from: $0)) }
            }
        })
        await waitUntil(root) { !placedTextViews(in: root).isEmpty }
        let views = placedTextViews(in: root)
        try #require(!views.isEmpty)
        #expect(views.count < messages.count)
        for view in views {
            await view.contentSettled()
            #expect(view.bounds.width > 0)
            #expect(view.bounds.height > 0)
            #expect(isAsTallAsItsText(view))
        }
    }

    @Test func aStreamedRowInALazyStackGrowsWithItsText() async throws {
        let stream = TranscriptStream(markdown: "The first words.")
        let root = show(ScrollView {
            LazyVStack(spacing: 8) {
                Text(verbatim: "A row above")
                TranscriptText(stream: stream)
                Text(verbatim: "A row below")
            }
        })
        await waitUntil(root) { placedTextViews(in: root).count == 1 }
        let view = try #require(placedTextViews(in: root).first)
        let before = view.bounds.height
        #expect(before > 0)

        stream.append("\n\n" + longParagraph)
        stream.finish()
        stream.flush()
        await view.contentSettled()
        await waitUntil(root) { view.bounds.height > before && isAsTallAsItsText(view) }
        #expect(view.bounds.height > before)
        #expect(isAsTallAsItsText(view))
    }

    @Test func theLineLimitOfTheEnvironmentWins() async throws {
        let document = MarkdownStreamParser.document(from: longParagraph)
        let root = show(VStack {
            TranscriptText(document).lineLimit(2)
            Spacer()
        })
        await waitUntil(root) { placedTextViews(in: root).count == 1 }
        let view = try #require(placedTextViews(in: root).first)
        await view.contentSettled()
        #expect(view.style.lineLimit == 2)
        let cut = DocumentLayout(document: document, width: view.bounds.width, style: view.style)
        #expect(view.bounds.height == ceil(cut.height))
        #expect(cut.height < DocumentLayout(document: document, width: view.bounds.width).height)
    }
}
#endif
