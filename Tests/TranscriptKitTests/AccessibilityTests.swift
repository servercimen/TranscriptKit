import CoreGraphics
import Foundation
import Testing
@testable import TranscriptKit

private let longParagraph = String(repeating: "Words that wrap onto several lines. ", count: 8)

private func limited(_ limit: Int?) -> TranscriptStyle {
    var style = TranscriptStyle()
    style.lineLimit = limit
    return style
}

@Test func aBlockCutByALineLimitIsReadWhole() {
    let document = MarkdownStreamParser.document(from: longParagraph)
    let cut = DocumentLayout(document: document, width: 200, style: limited(2))
    #expect(cut.leavesTextOut)
    let items = cut.accessibilityItems()
    #expect(items.count == 1)
    #expect(items[0].label == document.block(at: 0).text)
    #expect(items[0].frame == cut.entry(at: 0).frame)
}

@Test func blocksLeftOutByALineLimitAreReadWithTheLastOneShown() {
    let document = MarkdownStreamParser.document(from: "First.\n\nSecond with a [link](https://example.com).\n\n- [x] Third")
    let cut = DocumentLayout(document: document, width: 300, style: limited(1))
    let items = cut.accessibilityItems()
    #expect(items.count == 1)
    #expect(items[0].label == "First.\nSecond with a link.\nChecked, Third")
    #expect(items[0].links.map(\.url.absoluteString) == ["https://example.com"])
}

@Test func textWithinTheLineLimitIsReadAsBefore() {
    let document = MarkdownStreamParser.document(from: "# Title\n\nBody.")
    let items = DocumentLayout(document: document, width: 300, style: limited(5)).accessibilityItems()
    #expect(items.map(\.label) == ["Title", "Body."])
    #expect(items.map(\.isHeading) == [true, false])
}

@Test func aSelectionToTheEndOfTheShownTextCoversTheRest() {
    let document = MarkdownStreamParser.document(from: "First.\n\n" + longParagraph + "\n\nLast.")
    let cut = DocumentLayout(document: document, width: 200, style: limited(2))
    #expect(cut.length < document.utf16Count)
    let all = cut.documentRange(forSelection: 0..<cut.length)
    #expect(all == 0..<document.utf16Count)
    #expect(document.copyText(in: all).hasSuffix("Last."))
    #expect(cut.documentRange(forSelection: 3..<cut.length) == 3..<document.utf16Count)
    // A selection that ends before the end of the shown text keeps its end.
    #expect(cut.documentRange(forSelection: 0..<4) == 0..<4)
    // A caret stays a caret.
    #expect(cut.documentRange(forSelection: cut.length..<cut.length).isEmpty)
}

@Test func withoutALineLimitASelectionIsTheSameRange() {
    let document = MarkdownStreamParser.document(from: "First.\n\nSecond.")
    let full = DocumentLayout(document: document, width: 300, style: limited(nil))
    #expect(!full.leavesTextOut)
    #expect(full.documentRange(forSelection: 0..<full.length) == 0..<full.length)
}

@Test func imagesAndFormulasAreReadAsTheirText() {
    let block = MarkdownStreamParser.document(from: "See ![a cat](cat.png) and \\(x^2\\).").block(at: 0)
    #expect(AccessibilityText.readable(block, in: 0..<block.utf16Count) == "See a cat and x^2.")
}

@Test func itemsKeepTheirBlocksKeysWhileTextStreams() {
    var parser = MarkdownStreamParser()
    parser.append("# Title\n\nFirst words")
    let before = DocumentLayout(document: parser.document, width: 300)
    parser.append(" and more words")
    let longer = DocumentLayout(document: parser.document, width: 300, reusing: before)
    parser.append("\n\nA new paragraph")
    let added = DocumentLayout(document: parser.document, width: 300, reusing: longer)
    let keys = before.accessibilityItems().map(\.key)
    #expect(keys.count == 2)
    #expect(longer.accessibilityItems().map(\.key) == keys)
    #expect(Array(added.accessibilityItems().map(\.key).prefix(2)) == keys)
    #expect(added.accessibilityItems().count == 3)
    // Text added to the last block keeps the shape; a new block changes it.
    #expect(longer.accessibilityGeometry.hasSameElements(as: before.accessibilityGeometry))
    #expect(!added.accessibilityGeometry.hasSameElements(as: longer.accessibilityGeometry))
}

@Test func blocksWithTheSameIdGetDifferentKeys() {
    let document = TranscriptDocument(blocks: [TranscriptBlock(id: "same", text: "One"), TranscriptBlock(id: "same", text: "Two"),
                                               TranscriptBlock(id: "same#1", text: "Three")])
    let keys = DocumentLayout(document: document, width: 300).accessibilityItems().map(\.key)
    #expect(keys.count == 3)
    #expect(Set(keys).count == 3)
}

@Test func aBlockWithoutTextYetChangesTheShapeWhenItGetsSome() {
    var document = TranscriptDocument(blocks: [TranscriptBlock(id: "a", text: "One")])
    document.append(TranscriptBlock(id: "b", text: ""))
    let empty = DocumentLayout(document: document, width: 300)
    document.appendToLastBlock("Two")
    let filled = DocumentLayout(document: document, width: 300, reusing: empty)
    #expect(empty.accessibilityItems().count == 1)
    #expect(filled.accessibilityItems().count == 2)
    #expect(!empty.accessibilityGeometry.hasSameElements(as: filled.accessibilityGeometry))
}

private func items(_ markdown: String, width: CGFloat = 300) -> [AccessibilityItem] {
    DocumentLayout(document: MarkdownStreamParser.document(from: markdown), width: width).accessibilityItems()
}

@Test func listItemsTellTheirPositionAndTheItemCount() {
    let list = items("- One\n- Two\n  more of two\n\n  A second paragraph\n- Three")
    #expect(list.map(\.label) == ["One", "Two more of two", "A second paragraph", "Three"])
    #expect(list.map(\.value) == ["Item 1 of 3", "Item 2 of 3", nil, "Item 3 of 3"])
}

@Test func nestedListsAndSeparateListsCountOnTheirOwn() {
    let list = items("1. One\n   - Inner a\n   - Inner b\n2. Two\n\nText.\n\n- [ ] Task\n- Bullet\n\n3) Other")
    #expect(list.map(\.value) == ["Item 1 of 2", "Item 1 of 2", "Item 2 of 2", "Item 2 of 2", nil, "Item 1 of 2", "Item 2 of 2",
                                  "Item 1 of 1"])
}

@Test func numbersWithAnotherDelimiterStartANewList() {
    let list = items("1. One\n2. Two\n1) Other")
    #expect(list.map(\.value) == ["Item 1 of 2", "Item 2 of 2", "Item 1 of 1"])
}

@Test func theItemCountTakesInItemsThatALineLimitLeavesOut() {
    var style = TranscriptStyle()
    style.lineLimit = 1
    let document = MarkdownStreamParser.document(from: "- One\n- Two\n- Three")
    let list = DocumentLayout(document: document, width: 300, style: style).accessibilityItems()
    #expect(list.map(\.value) == ["Item 1 of 3"])
}

@Test func aTableHasOneItemForEachCell() throws {
    let list = items("Before.\n\n| Name | Value |\n| --- | ---: |\n| a | [one](https://example.com/1) |\n| b | \\(x^2\\) |")
    #expect(list.count == 2)
    let table = try #require(list[1].table)
    #expect(table.rowCount == 3)
    #expect(table.columnCount == 2)
    #expect(table.cells.map(\.label) == ["Name", "Value", "a", "one", "b", "x^2"])
    #expect(table.cells.map(\.row) == [0, 0, 1, 1, 2, 2])
    #expect(table.cells.map(\.column) == [0, 1, 0, 1, 0, 1])
    #expect(table.cells[3].links.map(\.url.absoluteString) == ["https://example.com/1"])
    // Cells sit side by side in their rows, inside the table's frame.
    #expect(table.cells[0].frame.maxX <= table.cells[1].frame.minX + 0.5)
    #expect(table.cells[0].frame.maxY <= table.cells[2].frame.minY + 0.5)
    #expect(table.cells.allSatisfy { list[1].frame.insetBy(dx: -0.5, dy: -0.5).contains($0.frame) })
}

@Test func theCellsOfARightToLeftTableAreWhereTheirTextIs() throws {
    let layout = DocumentLayout(document: MarkdownStreamParser.document(from: "| שם | ערך |\n| --- | --- |\n| א | ב |"), width: 300)
    let block = layout.entry(at: 0).layout
    #expect(block.isRightToLeft)
    let grid = try #require(block.table)
    let table = try #require(layout.accessibilityItems().first?.table)
    #expect(table.cells.map(\.label) == ["שם", "ערך", "א", "ב"])
    // The first column is the one on the right.
    #expect(table.cells[0].frame.minX >= table.cells[1].frame.maxX - 0.5)
    for cell in table.cells {
        let line = block.lines[grid.cellLines[cell.row][cell.column].lowerBound]
        #expect(cell.frame.minX <= line.frame.minX && line.frame.maxX <= cell.frame.maxX, "\(cell.label)")
    }
}

@Test func aTableThatStreamsInChangesTheShapeWithEachCell() {
    var parser = MarkdownStreamParser()
    parser.append("| A | B |\n| - | - |\n| 1 |")
    let before = DocumentLayout(document: parser.document, width: 300)
    parser.append(" 2 |")
    let after = DocumentLayout(document: parser.document, width: 300, reusing: before)
    #expect(!before.accessibilityGeometry.hasSameElements(as: after.accessibilityGeometry))
    #expect(after.accessibilityItems().first?.table?.cells.count == 4)
}

@Test func textLeftOutAfterATableGetsAnItemOfItsOwn() {
    var style = TranscriptStyle()
    style.lineLimit = 3
    let document = MarkdownStreamParser.document(from: "| A | B |\n| - | - |\n| 1 | 2 |\n\nAfter the table.")
    let list = DocumentLayout(document: document, width: 300, style: style).accessibilityItems()
    #expect(list.count == 2)
    #expect(list[0].table != nil)
    #expect(list[1].label == "After the table.")
}

@Test func formulasAreReadWithTheWordsTheAppGives() {
    let document = MarkdownStreamParser.document(from: "Area: \\(\\pi r^2\\).")
    let layout = DocumentLayout(document: document, width: 300)
    #expect(layout.accessibilityItems().map(\.label) == ["Area: \\pi r^2."])
    let spoken = layout.accessibilityItems { $0.tex == "\\pi r^2" ? "pi r squared" : $0.tex }
    #expect(spoken.map(\.label) == ["Area: pi r squared."])
}

private func isNeeded(from old: DocumentLayout, to new: DocumentLayout, isAppend: Bool) -> Bool {
    var watch = AccessibilityLayoutWatch()
    watch.start(with: old)
    return watch.install(new, isAppend: isAppend)
}

@Test func aLayoutChangeIsPostedOnlyWhenElementsChange() {
    var parser = MarkdownStreamParser()
    parser.append("# Title\n\nFirst words")
    let before = DocumentLayout(document: parser.document, width: 300)
    // The same text laid out again, as after new colors for code: nothing to tell.
    #expect(!isNeeded(from: before, to: DocumentLayout(document: parser.document, width: 300), isAppend: false))
    // Another width moves the elements.
    #expect(isNeeded(from: before, to: DocumentLayout(document: parser.document, width: 200), isAppend: false))
    parser.append(" and more")
    let longer = DocumentLayout(document: parser.document, width: 300, reusing: before)
    #expect(!isNeeded(from: before, to: longer, isAppend: true))
    parser.append("\n\nA new paragraph")
    let added = DocumentLayout(document: parser.document, width: 300, reusing: longer)
    #expect(isNeeded(from: longer, to: added, isAppend: true))
}

@Test func textThatStreamsInAfterATableUnderALineLimitChangesTheShape() {
    var style = TranscriptStyle()
    style.lineLimit = 3
    var parser = MarkdownStreamParser()
    parser.append("| A | B |\n| - | - |\n| 1 | 2 |\n\n")
    let before = DocumentLayout(document: parser.document, width: 300, style: style)
    parser.append("After")
    let after = DocumentLayout(document: parser.document, width: 300, style: style)
    #expect(before.accessibilityItems().count == 1)
    #expect(after.accessibilityItems().count == 2)
    #expect(isNeeded(from: before, to: after, isAppend: true))
}

@Test func aTableThatStartsAListItemTellsTheMarkerAndThePosition() throws {
    let list = items("1. First\n2. | A | B |\n   | - | - |\n   | 1 | 2 |\n3. Third")
    #expect(list.count == 3)
    let table = try #require(list[1].table)
    #expect(table.cells.map(\.label) == ["2. A", "B", "1", "2"])
    #expect(table.cells.map(\.value) == ["Item 2 of 3", nil, nil, nil])
}

@Test func blocksWhoseLayoutDidNotChangeKeepTheirWords() {
    var parser = MarkdownStreamParser()
    parser.append("Area: \\(\\pi r^2\\).\n\n| A | B |\n| - | - |\n| \\(x\\) | [y](https://example.com) |\n\nFirst words")
    let before = DocumentLayout(document: parser.document, width: 300)
    parser.append(" and more")
    let longer = DocumentLayout(document: parser.document, width: 300, reusing: before)
    var calls = 0
    let words = AccessibilityWords()
    let math = { (formula: TranscriptMath) -> String in
        calls += 1
        return formula.tex
    }
    let first = before.accessibilityItems(math: math, words: words)
    let callsBefore = calls
    #expect(callsBefore >= 2)
    let second = longer.accessibilityItems(math: math, words: words)
    #expect(calls == callsBefore)
    #expect(second.map(\.label) == ["Area: \\pi r^2.", "", "First words and more"])
    #expect(second[1] == first[1])
    #expect(second[1].table?.cells.map(\.label) == ["A", "B", "x", "y"])
    #expect(second[1].table?.cells[3].links.map(\.url.absoluteString) == ["https://example.com"])
}

@Test func newLinkDefinitionsMakeTheWordsAgain() {
    let words = AccessibilityWords()
    var parser = MarkdownStreamParser()
    parser.append("See [docs][d].\n\nMore")
    let before = DocumentLayout(document: parser.document, width: 300)
    #expect(before.accessibilityItems(words: words)[0].links.isEmpty)
    parser.append(" text\n\n[d]: https://example.com/docs\n")
    let after = DocumentLayout(document: parser.document, width: 300, reusing: before)
    #expect(after.accessibilityItems(words: words)[0].links.map(\.url.absoluteString) == ["https://example.com/docs"])
}

@Test func newColorsAfterTextStreamedInPostNothing() {
    var parser = MarkdownStreamParser()
    parser.append("Intro.\n\n```swift\nlet a = 1")
    var layout = DocumentLayout(document: parser.document, width: 300)
    var watch = AccessibilityLayoutWatch()
    watch.start(with: layout)
    var posts = 0
    for line in ["\nlet b = 2", "\nlet c = 3", "\nlet d = 4"] {
        parser.append(line)
        layout = DocumentLayout(document: parser.document, width: 300, reusing: layout)
        if watch.install(layout, isAppend: true) { posts += 1 }
    }
    #expect(posts == 0)
    // The same text laid out again, as after the code's colors arrive.
    if watch.install(DocumentLayout(document: parser.document, width: 300), isAppend: false) { posts += 1 }
    #expect(posts == 0)
    // A new width moves the elements.
    let moved = watch.install(DocumentLayout(document: parser.document, width: 200), isAppend: false)
    #expect(moved)
}
