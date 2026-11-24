#if canImport(UIKit) && !os(watchOS)
import Foundation
import Testing
import UIKit
@testable import TranscriptKit

/// Lets the main actor run until `condition` holds, for at most two seconds.
@MainActor
private func wait(until condition: () -> Bool) async {
    let deadline = Date(timeIntervalSinceNow: 2)
    while !condition(), Date() < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
private func elements(of view: TranscriptTextView) -> [UIAccessibilityElement] {
    (view.accessibilityElements as? [UIAccessibilityElement]) ?? []
}

@MainActor
@Test func elementsStayTheSameObjectsWhileTextStreams() async {
    let view = TranscriptTextView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
    let parser = { (markdown: String) in MarkdownStreamParser.document(from: markdown, idPrefix: "t") }
    view.document = parser("# Title\n\nFirst words")
    view.layoutIfNeeded()
    let before = elements(of: view)
    #expect(before.map(\.accessibilityLabel) == ["Title", "First words"])

    view.document = parser("# Title\n\nFirst words and more")
    await wait { elements(of: view).last?.accessibilityLabel == "First words and more" }
    let longer = elements(of: view)
    #expect(longer.count == 2)
    #expect(zip(before, longer).allSatisfy { $0 === $1 })

    view.document = parser("# Title\n\nFirst words and more\n\nNew block")
    await wait { elements(of: view).count == 3 }
    let added = elements(of: view)
    #expect(added.count == 3)
    #expect(added[0] === before[0] && added[1] === before[1])

    view.frame.size.width = 200
    view.layoutIfNeeded()
    let narrower = elements(of: view)
    #expect(zip(added, narrower).allSatisfy { $0 === $1 })
    #expect((narrower[1] as? TextAccessibilityElement)?.frameInView.width == 200)
}

@MainActor
@Test func anElementThatAClientHoldsShowsTheNewText() async {
    let view = TranscriptTextView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
    let parser = { (markdown: String) in MarkdownStreamParser.document(from: markdown, idPrefix: "t") }
    view.document = parser("# Title\n\nFirst words")
    view.layoutIfNeeded()
    let held = elements(of: view)[1]
    let length = (view.endOfDocument as? TranscriptTextPosition)?.offset ?? 0
    view.document = parser("# Title\n\nFirst words and more")
    // Waits for the new layout without asking the view for its elements.
    await wait { ((view.endOfDocument as? TranscriptTextPosition)?.offset ?? 0) > length }
    #expect(held.accessibilityLabel == "First words and more")
}

@MainActor
@Test func aTableIsADataTableOfCells() throws {
    let view = TranscriptTextView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
    view.document = MarkdownStreamParser.document(from: "- One\n- Two\n\n| A | B |\n| - | - |\n| 1 | 2 |")
    view.layoutIfNeeded()
    let all = elements(of: view)
    #expect(all.count == 3)
    #expect(all[1].accessibilityValue == "Item 2 of 2")
    let table = try #require(all[2] as? UIAccessibilityContainerDataTable & UIAccessibilityElement)
    #expect(table.accessibilityContainerType == .dataTable)
    #expect(table.accessibilityRowCount() == 2)
    #expect(table.accessibilityColumnCount() == 2)
    let cell = try #require(table.accessibilityDataTableCellElement(forRow: 1, column: 1) as? UIAccessibilityElement)
    #expect(cell.accessibilityLabel == "2")
    #expect(cell.accessibilityContainer as AnyObject === table)
    #expect((table.accessibilityElements ?? []).count == 4)
    let header = table.accessibilityHeaderElements?(forColumn: 1)?.first as? UIAccessibilityElement
    #expect(header?.accessibilityLabel == "B")
}

@MainActor
@Test func formulasUseTheLabelTheAppSets() {
    let view = TranscriptTextView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
    view.document = MarkdownStreamParser.document(from: "Area: \\(\\pi r^2\\).")
    view.layoutIfNeeded()
    #expect(elements(of: view).first?.accessibilityLabel == "Area: \\pi r^2.")
    view.mathAccessibilityLabel = { _ in "pi r squared" }
    #expect(elements(of: view).first?.accessibilityLabel == "Area: pi r squared.")
}
@MainActor
@Test func selectAllUnderALineLimitCopiesAllOfTheText() async {
    let view = TranscriptTextView(frame: CGRect(x: 0, y: 0, width: 200, height: 400))
    var parser = MarkdownStreamParser()
    parser.append(String(repeating: "Words that wrap onto several lines. ", count: 6) + "\n\n## Later heading\n\nLast")
    view.document = parser.document
    var style = view.style
    style.lineLimit = 2
    view.style = style
    view.layoutIfNeeded()
    var reported: [Range<Int>?] = []
    view.onSelectionChange = { reported.append($0) }
    view.selectAll(nil)
    let shown = (view.endOfDocument as? TranscriptTextPosition)?.offset ?? 0
    #expect(shown < parser.document.utf16Count)
    #expect(view.selectedRange == 0..<parser.document.utf16Count)
    // What `copy(_:)` puts on the pasteboard.
    #expect(view.selectedRange.map { parser.document.copyText(in: $0) }?.hasSuffix("Last") == true)
    #expect(view.selectedText?.hasSuffix("Last") == true)
    #expect(reported == [0..<parser.document.utf16Count])
    // The selection grows with text that streams in after the cut.
    parser.append(" paragraph.")
    view.document = parser.document
    await wait { view.selectedRange == 0..<parser.document.utf16Count }
    #expect(view.selectedRange == 0..<parser.document.utf16Count)
    #expect(reported.last == 0..<parser.document.utf16Count)
    #expect(view.selectedText?.hasSuffix("Last paragraph.") == true)
}

@MainActor
@Test func anElementReadsAllOfTheTextUnderALineLimit() {
    let view = TranscriptTextView(frame: CGRect(x: 0, y: 0, width: 200, height: 400))
    view.document = MarkdownStreamParser.document(from: "First paragraph that wraps onto lines.\n\nSecond.")
    var style = view.style
    style.lineLimit = 1
    view.style = style
    view.layoutIfNeeded()
    #expect(elements(of: view).map(\.accessibilityLabel) == ["First paragraph that wraps onto lines.\nSecond."])
}
#endif
