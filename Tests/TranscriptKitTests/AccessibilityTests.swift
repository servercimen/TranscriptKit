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
    #expect(longer.accessibilityShape == before.accessibilityShape)
    #expect(added.accessibilityShape != longer.accessibilityShape)
}

@Test func blocksWithTheSameIdGetDifferentKeys() {
    let document = TranscriptDocument(blocks: [TranscriptBlock(id: "same", text: "One"), TranscriptBlock(id: "same", text: "Two")])
    let keys = DocumentLayout(document: document, width: 300).accessibilityItems().map(\.key)
    #expect(keys.count == 2)
    #expect(Set(keys).count == 2)
}

@Test func aBlockWithoutTextYetChangesTheShapeWhenItGetsSome() {
    var document = TranscriptDocument(blocks: [TranscriptBlock(id: "a", text: "One")])
    document.append(TranscriptBlock(id: "b", text: ""))
    let empty = DocumentLayout(document: document, width: 300)
    document.appendToLastBlock("Two")
    let filled = DocumentLayout(document: document, width: 300, reusing: empty)
    #expect(empty.accessibilityItems().count == 1)
    #expect(filled.accessibilityItems().count == 2)
    #expect(empty.accessibilityShape != filled.accessibilityShape)
}
