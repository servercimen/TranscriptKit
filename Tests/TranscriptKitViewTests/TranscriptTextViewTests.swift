#if canImport(UIKit) && !os(watchOS)
import Testing
import UIKit
@testable import TranscriptKit

private let longParagraph = String(repeating: "Words that wrap onto several lines. ", count: 8)
private let linked = "Read [the guide](https://example.com/guide) before you start."

@MainActor
private func makeView(_ markdown: String, width: CGFloat = 320, style: TranscriptStyle = .init(),
                      in window: UIWindow? = nil) -> TranscriptTextView {
    let view = TranscriptTextView(frame: CGRect(x: 0, y: 0, width: width, height: 400))
    view.style = style
    window?.addSubview(view)
    view.document = MarkdownStreamParser.document(from: markdown)
    return view
}

/// The height that the view must have: the layout's own, at the same width and style.
private func expectedHeight(_ markdown: String, width: CGFloat, style: TranscriptStyle = .init()) -> CGFloat {
    ceil(DocumentLayout(document: MarkdownStreamParser.document(from: markdown), width: width, style: style).height)
}

private func limited(_ limit: Int?) -> TranscriptStyle {
    var style = TranscriptStyle()
    style.lineLimit = limit
    return style
}

@MainActor
private func textRange(_ range: Range<Int>, in view: TranscriptTextView) throws -> UITextRange {
    let start = try #require(view.position(from: view.beginningOfDocument, offset: range.lowerBound))
    let end = try #require(view.position(from: view.beginningOfDocument, offset: range.upperBound))
    return try #require(view.textRange(from: start, to: end))
}

/// The middle of the first line of `range` on screen.
@MainActor
private func center(of range: Range<Int>, in view: TranscriptTextView) throws -> CGPoint {
    let rect = view.firstRect(for: try textRange(range, in: view))
    return CGPoint(x: rect.midX, y: rect.midY)
}

@MainActor
private func documentLength(of view: TranscriptTextView) -> Int {
    view.offset(from: view.beginningOfDocument, to: view.endOfDocument)
}

@MainActor
private func hasTextInteraction(_ view: TranscriptTextView) -> Bool {
    view.interactions.contains { $0 is UITextInteraction }
}

@Suite(.serialized) @MainActor
struct TranscriptTextViewTests {
    /// Windows of a fixed size, so that no test depends on the screen. Each
    /// test has its own, and they last as long as the test.
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
    let otherWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))

    // MARK: Sizing

    @Test func aSizedViewIsAsTallAsItsLayout() {
        let view = makeView(longParagraph, width: 300)
        let height = expectedHeight(longParagraph, width: 300)
        #expect(height > 0)
        #expect(view.intrinsicContentSize.height == height)
        #expect(view.sizeThatFits(CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude)) == CGSize(width: 300, height: height))
    }

    @Test func anUnsizedViewMeasuresAtTheProposedWidth() {
        let view = TranscriptTextView(frame: .zero)
        view.document = MarkdownStreamParser.document(from: longParagraph)
        let wide = view.sizeThatFits(CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        let narrow = view.sizeThatFits(CGSize(width: 150, height: CGFloat.greatestFiniteMagnitude))
        #expect(wide == CGSize(width: 300, height: expectedHeight(longParagraph, width: 300)))
        #expect(narrow == CGSize(width: 150, height: expectedHeight(longParagraph, width: 150)))
        #expect(narrow.height > wide.height)
    }

    @Test func emptyTextHasNoHeight() async {
        let view = TranscriptTextView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        #expect(view.sizeThatFits(CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude)).height == 0)
        #expect(view.intrinsicContentSize.height == UIView.noIntrinsicMetric)
        #expect(!view.hasText)

        view.document = MarkdownStreamParser.document(from: "Hello")
        #expect(view.intrinsicContentSize.height > 0)
        view.document = TranscriptDocument()
        await view.contentSettled()
        #expect(view.intrinsicContentSize.height == 0)
        #expect(view.sizeThatFits(CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude)).height == 0)
        #expect(!view.hasText)
    }

    @Test func aNewWidthLaysOutAgain() {
        let view = makeView(longParagraph, width: 300)
        view.frame.size.width = 150
        view.layoutIfNeeded()
        #expect(view.intrinsicContentSize.height == expectedHeight(longParagraph, width: 150))
    }

    // MARK: First layout

    @Test func theFirstLayoutOfPlainTextIsSynchronous() {
        let view = TranscriptTextView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        let document = MarkdownStreamParser.document(from: longParagraph)
        view.document = document
        #expect(view.hasText)
        #expect(documentLength(of: view) == DocumentLayout(document: document, width: 320).length)
        #expect(view.intrinsicContentSize.height == expectedHeight(longParagraph, width: 320))
    }

    @Test func theFirstLayoutOfAStreamIsSynchronous() {
        let view = TranscriptTextView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        view.stream = TranscriptStream(markdown: longParagraph)
        #expect(view.hasText)
        #expect(view.intrinsicContentSize.height == expectedHeight(longParagraph, width: 320))
    }

    @Test func aStreamedAppendArrivesLater() async {
        let view = TranscriptTextView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        window.addSubview(view)
        let stream = TranscriptStream(markdown: "First paragraph.\n\n")
        view.stream = stream
        let before = view.intrinsicContentSize.height
        view.select(0..<5)

        stream.append(longParagraph)
        stream.finish()
        stream.flush()
        await view.contentSettled()

        let markdown = "First paragraph.\n\n" + longParagraph
        #expect(view.intrinsicContentSize.height == expectedHeight(markdown, width: 320))
        #expect(view.intrinsicContentSize.height > before)
        #expect(documentLength(of: view) == DocumentLayout(document: MarkdownStreamParser.document(from: markdown), width: 320).length)
        #expect(view.selectedRange == 0..<5)
    }

    // MARK: Line limit

    @Test func aLineLimitCutsTheHeightAndTheText() {
        let view = makeView(longParagraph, width: 200, style: limited(2))
        let full = DocumentLayout(document: MarkdownStreamParser.document(from: longParagraph), width: 200)
        let cut = DocumentLayout(document: MarkdownStreamParser.document(from: longParagraph), width: 200, style: limited(2))
        #expect(cut.length < full.length)
        #expect(view.intrinsicContentSize.height == ceil(cut.height))
        #expect(view.intrinsicContentSize.height < ceil(full.height))
        #expect(view.sizeThatFits(CGSize(width: 200, height: CGFloat.greatestFiniteMagnitude)).height == ceil(cut.height))

        view.selectAll(nil)
        #expect(view.selectedRange == 0..<cut.length)
    }

    @Test func removingTheLineLimitShowsAllLines() {
        let view = makeView(longParagraph, width: 200, style: limited(2))
        view.style = limited(nil)
        #expect(view.intrinsicContentSize.height == expectedHeight(longParagraph, width: 200))
    }

    // MARK: Selection

    @Test func selectReportsEachChangeOnce() {
        let view = makeView(longParagraph)
        var changes: [Range<Int>?] = []
        view.onSelectionChange = { changes.append($0) }

        view.select(6..<10)
        view.select(6..<10)
        #expect(view.selectedRange == 6..<10)
        #expect(view.selectedText == "that")
        #expect(hasTextInteraction(view))

        view.select(nil)
        #expect(view.selectedRange == nil)
        #expect(view.selectedText == nil)
        #expect(changes == [6..<10, nil])
    }

    @Test func selectKeepsTheRangeInTheText() {
        let view = makeView("Hello")
        view.select(2..<1000)
        #expect(view.selectedRange == 2..<5)
        view.select(3..<3)
        #expect(view.selectedRange == nil)
    }

    @Test func selectAllSelectsTheWholeText() {
        let view = makeView(linked)
        #expect(view.canPerformAction(#selector(UIResponderStandardEditActions.selectAll(_:)), withSender: nil))
        #expect(!view.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil))

        view.selectAll(nil)
        #expect(view.selectedRange == 0..<documentLength(of: view))
        #expect(view.selectedText == "Read the guide before you start.")
        #expect(view.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil))
        #expect(!view.canPerformAction(#selector(UIResponderStandardEditActions.selectAll(_:)), withSender: nil))
        #expect(!view.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil))
    }

    @Test func selectsAllWhenShownWaitsForAWindow() {
        let view = makeView(longParagraph)
        view.selectsAllWhenShown = true
        #expect(view.selectedRange == nil)

        window.addSubview(view)
        #expect(view.selectedRange == 0..<documentLength(of: view))
    }

    @Test func turningOffSelectionClearsIt() {
        let view = makeView(longParagraph)
        view.select(0..<5)
        view.isSelectable = false
        #expect(view.selectedRange == nil)
        #expect(!hasTextInteraction(view))
        #expect(!view.canBecomeFirstResponder)
    }

    @Test func oneViewInAWindowHasASelection() throws {
        let first = makeView(longParagraph, in: window)
        let second = makeView(longParagraph, in: window)
        let elsewhere = makeView(longParagraph, in: otherWindow)
        var firstChanges: [Range<Int>?] = []
        first.onSelectionChange = { firstChanges.append($0) }

        first.select(0..<5)
        elsewhere.select(0..<5)
        try #require(second.becomeFirstResponder())
        second.select(6..<10)

        #expect(first.selectedRange == nil)
        #expect(firstChanges == [0..<5, nil])
        #expect(second.selectedRange == 6..<10)
        #expect(elsewhere.selectedRange == 0..<5)
    }

    @Test func aViewThatLeavesItsWindowClearsItsSelection() {
        let view = makeView(longParagraph, in: window)
        var changes: [Range<Int>?] = []
        view.onSelectionChange = { changes.append($0) }
        view.select(0..<5)

        view.removeFromSuperview()
        #expect(view.window == nil)
        #expect(view.selectedRange == nil)
        #expect(changes == [0..<5, nil])
    }

    @Test func aViewThatMovesToAnotherWindowKeepsItsSelection() {
        let view = makeView(longParagraph, in: window)
        view.select(0..<5)

        otherWindow.addSubview(view)
        #expect(view.window === otherWindow)
        #expect(view.selectedRange == 0..<5)
    }

    // MARK: Hit testing

    @Test func aSelectableViewTakesEveryTouchInside() throws {
        let view = makeView(linked)
        #expect(!hasTextInteraction(view))
        let word = try center(of: 0..<4, in: view)
        #expect(view.point(inside: word, with: nil))
        #expect(hasTextInteraction(view))
        #expect(view.point(inside: CGPoint(x: view.bounds.maxX - 1, y: view.bounds.maxY - 1), with: nil))
        #expect(!view.point(inside: CGPoint(x: -1, y: -1), with: nil))
    }

    @Test func anUnselectableViewTakesOnlyTouchesOnLinks() throws {
        let view = makeView(linked)
        view.isSelectable = false
        let document = MarkdownStreamParser.document(from: linked)
        let span = try #require(document.block(at: 0).spans.first { $0.link != nil })
        #expect(document.text(in: span.range) == "the guide")

        #expect(view.point(inside: try center(of: span.range, in: view), with: nil))
        #expect(!view.point(inside: try center(of: 0..<4, in: view), with: nil))
        #expect(!view.point(inside: CGPoint(x: view.bounds.maxX - 1, y: view.bounds.maxY - 1), with: nil))
        #expect(!hasTextInteraction(view))
    }
}
#endif
