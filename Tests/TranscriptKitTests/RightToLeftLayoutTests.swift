import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import TranscriptKit

private let hebrew = String(repeating: "שלום עולם, זה משפט ארוך בעברית. ", count: 5)
private let arabic = "مرحبا بالعالم"

private func layout(_ markdown: String, width: CGFloat = 300, style: TranscriptStyle = .init()) -> DocumentLayout {
    DocumentLayout(document: MarkdownStreamParser.document(from: markdown), width: width, style: style)
}

/// Each line's text range and frame, for comparing two layouts.
private func lineSummary(_ layout: BlockLayout) -> [String] {
    layout.lines.map { "\($0.range) \($0.frame) \($0.baseline)" }
}

// MARK: Lines

@Test func rightToLeftParagraphLinesEndAtTheRightEdge() {
    let block = layout(hebrew).entry(at: 0).layout
    #expect(block.isRightToLeft)
    #expect(block.lines.count > 2)
    for line in block.lines {
        #expect(abs(line.frame.maxX - 300) < 0.01)
        // The first character of the line is at its right end.
        #expect(abs(block.caretRect(atOffset: line.range.lowerBound).midX - line.frame.maxX) < 1)
    }
}

@Test func leftToRightTextGetsNoDirection() {
    let block = layout("Plain text that wraps onto more than one line of the layout, with digits 123.").entry(at: 0).layout
    #expect(block.paragraphDirection == nil)
    #expect(!block.isRightToLeft)
    #expect(block.lines.allSatisfy { $0.frame.minX == 0 })
    let text = TranscriptStyle().attributedString(for: block.block)
    #expect(text.attribute(TranscriptStyle.paragraphStyleKey, at: 0, effectiveRange: nil) == nil)
}

@Test func eachParagraphHasItsOwnDirection() {
    let document = layout("Hello world\n\n\(arabic)\n\nThe word \(arabic) in English")
    #expect((0..<3).map { document.entry(at: $0).layout.isRightToLeft } == [false, true, false])
    #expect(document.entry(at: 2).layout.paragraphDirection == .leftToRight)
    #expect(document.entry(at: 2).layout.lines[0].frame.minX == 0)
}

@Test func alignmentIsFromTheLeadingEdgeOfTheParagraph() {
    var style = TranscriptStyle()
    style.textAlignment = .trailing
    let trailing = layout(arabic, style: style).entry(at: 0).layout.lines[0]
    #expect(trailing.frame.minX == 0)
    style.textAlignment = .center
    let centered = layout(arabic, style: style).entry(at: 0).layout.lines[0]
    #expect(abs((300 - centered.frame.maxX) - centered.frame.minX) <= 1)
}

@Test func codeStaysLeftToRight() {
    let block = layout("```\nlet name = \"\(arabic)\"\n```").entry(at: 0).layout
    #expect(block.paragraphDirection == .leftToRight)
    #expect(!block.isRightToLeft)
    #expect(block.lines[0].frame.minX == TranscriptStyle().codePadding)
}

@Test func truncatedRightToLeftLineKeepsItsWidth() {
    var style = TranscriptStyle()
    style.lineLimit = 1
    let line = layout(hebrew, style: style).entry(at: 0).layout.lines[0]
    #expect(abs(line.frame.maxX - 300) < 0.01)
    #expect(line.frame.width > 250)
}

// MARK: Lists and quotes

@Test func listMarkersAndQuoteBarsGoOnTheRight() {
    let style = TranscriptStyle()
    let document = layout("- \(arabic)\n- [ ] \(arabic)\n\n> \(arabic)\n\n1. \(arabic)")
    let bullet = document.entry(at: 0).layout
    guard case .text(_, let origin)? = bullet.marker else { Issue.record("no bullet"); return }
    #expect(bullet.lines[0].frame.maxX == 300 - style.listIndent)
    #expect(origin.x > bullet.lines[0].frame.maxX)
    #expect(origin.x < 300)

    guard case .checkbox(let box, _)? = document.entry(at: 1).layout.marker else { Issue.record("no checkbox"); return }
    #expect(box.minX > document.entry(at: 1).layout.lines[0].frame.maxX)
    #expect(box.maxX <= 300)

    let quote = document.entry(at: 2).layout
    #expect(quote.lines[0].frame.maxX == 300 - style.quoteIndent)
    #expect(document.quoteBars(at: 2).map(\.minX) == [297])

    // The number's period is on the side of the text.
    guard case .text(let number, _)? = document.entry(at: 3).layout.marker else { Issue.record("no number"); return }
    let runs = CTLineGetGlyphRuns(number) as! [CTRun]
    #expect(CTRunGetStringRange(runs[0]).location == 1)
}

@Test func leftToRightQuoteBarsStayOnTheLeft() {
    let document = layout("> quoted\n>\n> > nested")
    #expect(document.quoteBars(at: 0).map(\.minX) == [0])
    #expect(document.quoteBars(at: 1).map(\.minX) == [0, TranscriptStyle().quoteIndent])
}

// MARK: Tables

@Test func rightToLeftTableStartsOnTheRight() {
    let document = layout("| \(arabic) | ب |\n|---|---|\n| א | ב |")
    let block = document.entry(at: 0).layout
    #expect(block.isRightToLeft)
    guard let table = block.table else { Issue.record("no table"); return }
    #expect(table.columnX == table.columnX.sorted())
    #expect(table.columnX.last == 300)
    let first = block.lines[table.cellLines[0][0].lowerBound]
    let second = block.lines[table.cellLines[0][1].lowerBound]
    #expect(first.frame.minX > second.frame.minX)
    // A point in the right column hits the first cell.
    let offset = block.closestOffset(to: CGPoint(x: first.frame.midX, y: first.frame.midY))
    #expect(first.range.contains(offset) || offset == first.range.upperBound)
    #expect(table.minimumWidths[0].allSatisfy { $0 > TranscriptStyle().tableCellPadding * 2 })
}

@Test func columnAlignedToASideKeepsThatSideInRightToLeftText() {
    let padding = TranscriptStyle().tableCellPadding
    // ":---" is left, "---:" is right, and "---" is the leading edge: the right.
    let markdown = "| א | ב | ג |\n|:---|---:|---|\n| אחת ארוכה מאוד | שתיים ארוכה מאוד | שלוש ארוכה מאוד |"
    let block = layout(markdown, width: 400).entry(at: 0).layout
    #expect(block.isRightToLeft)
    guard let table = block.table else { Issue.record("no table"); return }
    let count = table.columnX.count
    func cell(_ column: Int) -> (line: BlockLayout.Line, left: CGFloat, right: CGFloat) {
        (block.lines[table.cellLines[0][column].lowerBound], table.columnX[count - 2 - column], table.columnX[count - 1 - column])
    }
    let left = cell(0)
    #expect(abs(left.line.frame.minX - (left.left + padding)) < 0.5)
    #expect(left.line.frame.maxX < left.right - padding - 1)
    let right = cell(1)
    #expect(abs(right.line.frame.maxX - (right.right - padding)) < 0.5)
    #expect(right.line.frame.minX > right.left + padding + 1)
    let leading = cell(2)
    #expect(abs(leading.line.frame.maxX - (leading.right - padding)) < 0.5)

    // The same marks in left-to-right text.
    let english = layout("| a | b |\n|:---|---:|\n| one long text | two long text |", width: 400).entry(at: 0).layout
    guard let grid = english.table else { Issue.record("no table"); return }
    let first = english.lines[grid.cellLines[0][0].lowerBound]
    let second = english.lines[grid.cellLines[0][1].lowerBound]
    #expect(abs(first.frame.minX - (grid.columnX[0] + padding)) < 0.5)
    #expect(abs(second.frame.maxX - (grid.columnX[2] - padding)) < 0.5)
}

@Test func eachTableCellKeepsTheDirectionOfItsOwnText() {
    let block = layout("| Word | Meaning |\n|---|---|\n| \(arabic)! | hello |").entry(at: 0).layout
    #expect(!block.isRightToLeft)
    guard let table = block.table else { Issue.record("no table"); return }
    // In right-to-left text, the "!" at the end is drawn at the left.
    let cell = block.lines[table.cellLines[1][0].lowerBound]
    let runs = CTLineGetGlyphRuns(cell.ctLine) as! [CTRun]
    #expect(CTRunGetStringRange(runs[0]).location == (arabic as NSString).length)
}

// MARK: Streaming

private func streamed(_ markdown: String, chunk: Int, width: CGFloat = 300) -> (grown: DocumentLayout, fresh: DocumentLayout) {
    var parser = MarkdownStreamParser(idPrefix: "s")
    var layout: DocumentLayout?
    var text = Substring(markdown)
    while !text.isEmpty {
        parser.append(String(text.prefix(chunk)))
        text = text.dropFirst(chunk)
        layout = DocumentLayout(document: parser.document, width: width, reusing: layout)
    }
    return (layout!, DocumentLayout(document: parser.document, width: width))
}

private let hebrewTable = "| מילה | פירוש |\n|---|---|\n" + (1...8).map { "| שורה \($0) | \(String(repeating: "מילה ", count: $0)) |" }.joined(separator: "\n")

@Test(arguments: [hebrew, "2024: " + hebrew, "Some English first, then " + hebrew, "- " + hebrew, "> 12 " + hebrew, hebrewTable])
func streamedRightToLeftTextIsLaidOutAsAWhole(markdown: String) {
    let (grown, fresh) = streamed(markdown, chunk: 7)
    #expect(grown.entryCount == fresh.entryCount)
    for index in 0..<fresh.entryCount {
        let a = grown.entry(at: index).layout
        let b = fresh.entry(at: index).layout
        #expect(a.paragraphDirection == b.paragraphDirection)
        #expect(lineSummary(a) == lineSummary(b))
    }
}

@Test func changeOfDirectionRedrawsTheGapAbove() {
    let first = MarkdownStreamParser.document(from: "Intro\n\n> 12 ")
    let second = MarkdownStreamParser.document(from: "Intro\n\n> 12 \(arabic)")
    let earlier = DocumentLayout(document: first, width: 300)
    let later = DocumentLayout(document: second, width: 300, reusing: earlier)
    #expect(!earlier.entry(at: 1).layout.isRightToLeft)
    #expect(later.entry(at: 1).layout.isRightToLeft)
    #expect(later.changes(since: earlier).top <= earlier.entry(at: 0).frame.maxY)
}
