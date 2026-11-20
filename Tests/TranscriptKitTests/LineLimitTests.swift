import CoreText
import Foundation
import Testing
@testable import TranscriptKit

private let longParagraph = String(repeating: "Words that wrap onto several lines. ", count: 8)

/// Whether the line draws an ellipsis glyph.
private func endsInEllipsis(_ line: CTLine) -> Bool {
    let runs = CTLineGetGlyphRuns(line) as! [CTRun]
    guard let run = runs.last, CTRunGetGlyphCount(run) > 0 else { return false }
    let font = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
    var character: UniChar = 0x2026
    var ellipsis: CGGlyph = 0
    guard CTFontGetGlyphsForCharacters(font, &character, &ellipsis, 1) else { return false }
    var last: CGGlyph = 0
    CTRunGetGlyphs(run, CFRange(location: CTRunGetGlyphCount(run) - 1, length: 1), &last)
    return last == ellipsis
}

private func limited(_ limit: Int?) -> TranscriptStyle {
    var style = TranscriptStyle()
    style.lineLimit = limit
    return style
}

@Test func aLineLimitKeepsTheFirstLinesOfAParagraph() {
    let document = MarkdownStreamParser.document(from: longParagraph)
    let full = DocumentLayout(document: document, width: 200, style: limited(nil))
    let cut = DocumentLayout(document: document, width: 200, style: limited(2))
    let fullLines = full.entry(at: 0).layout.lines
    let cutLines = cut.entry(at: 0).layout.lines
    #expect(fullLines.count > 3)
    #expect(cutLines.count == 2)
    #expect(cut.height == cutLines[1].frame.maxY)
    #expect(cut.length == fullLines[1].range.upperBound)
    #expect(cutLines[0].frame == fullLines[0].frame)
    #expect(cutLines[1].range == fullLines[1].range)
    #expect(!endsInEllipsis(cutLines[0].ctLine))
    #expect(endsInEllipsis(cutLines[1].ctLine))
    #expect(cutLines[1].frame.maxX <= 200)
}

@Test func aLineLimitStopsBeforeLaterBlocks() {
    let document = MarkdownStreamParser.document(from: "First.\n\nSecond.\n\nThird.")
    let cut = DocumentLayout(document: document, width: 300, style: limited(2))
    #expect(cut.entryCount == 2)
    let second = cut.entry(at: 1)
    // More text follows, so the last line shown gains an ellipsis and is wider.
    let plain = DocumentLayout(document: document, width: 300, style: limited(nil)).entry(at: 1)
    #expect(second.layout.lines[0].frame.width > plain.layout.lines[0].frame.width)
    #expect(endsInEllipsis(second.layout.lines[0].ctLine))
    #expect(!endsInEllipsis(cut.entry(at: 0).layout.lines[0].ctLine))
    #expect(cut.length == second.end)
}

@Test func textWithinTheLimitIsUnchanged() {
    let document = MarkdownStreamParser.document(from: "First.\n\nSecond.")
    let cut = DocumentLayout(document: document, width: 300, style: limited(5))
    let full = DocumentLayout(document: document, width: 300, style: limited(nil))
    #expect(cut.entryCount == 2)
    #expect(cut.height == full.height)
    #expect(cut.length == full.length)
    #expect(cut.entry(at: 1).layout.lines[0].frame == full.entry(at: 1).layout.lines[0].frame)
}

@Test func centredAndTrailingLinesMoveInTheirColumn() {
    let document = MarkdownStreamParser.document(from: "Short line")
    var centre = TranscriptStyle()
    centre.textAlignment = .center
    var trailing = TranscriptStyle()
    trailing.textAlignment = .trailing
    let leadingLine = DocumentLayout(document: document, width: 300, style: TranscriptStyle()).entry(at: 0).layout.lines[0]
    let centredLine = DocumentLayout(document: document, width: 300, style: centre).entry(at: 0).layout.lines[0]
    let trailingLine = DocumentLayout(document: document, width: 300, style: trailing).entry(at: 0).layout.lines[0]
    #expect(leadingLine.frame.minX == 0)
    #expect(abs(centredLine.frame.midX - 150) <= 1)
    #expect(abs(trailingLine.frame.maxX - 300) <= 1)
}

@Test func listItemsStayAtTheLeadingEdge() {
    let document = MarkdownStreamParser.document(from: "- An item")
    var centre = TranscriptStyle()
    centre.textAlignment = .center
    let leading = DocumentLayout(document: document, width: 300, style: TranscriptStyle()).entry(at: 0).layout.lines[0]
    let centred = DocumentLayout(document: document, width: 300, style: centre).entry(at: 0).layout.lines[0]
    #expect(centred.frame.minX == leading.frame.minX)
}
