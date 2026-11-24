import Foundation
import Testing
@testable import TranscriptKit

private func parse(_ markdown: String, newlines: Bool = true) -> [TranscriptBlock] {
    MarkdownStreamParser.document(from: markdown, newlinesAsLineBreaks: newlines).blocks
}

@Test func newlineInParagraphIsASpaceByDefault() {
    #expect(parse("one\ntwo\nthree", newlines: false).map(\.text) == ["one two three"])
    #expect(MarkdownStreamParser.document(from: "one\ntwo").blocks.map(\.text) == ["one two"])
}

@Test func newlineInParagraphIsALineBreakWithTheOption() {
    #expect(parse("one\ntwo\nthree").map(\.text) == ["one\ntwo\nthree"])
    #expect(parse("one\ntwo\nthree").map(\.kind) == [.paragraph])
    #expect(parse("one\n\ntwo").map(\.text) == ["one", "two"])
    #expect(parse("one \n  two\t\nthree").map(\.text) == ["one\ntwo\nthree"])
    #expect(parse("one\r\ntwo\r\n").map(\.text) == ["one\ntwo"])
}

@Test func hardBreaksStayOneLineBreakWithTheOption() {
    #expect(parse("one  \ntwo").map(\.text) == ["one\ntwo"])
    for newlines in [false, true] {
        #expect(parse("one\\\ntwo", newlines: newlines).map(\.text) == ["one\ntwo"])
        #expect(parse("one \\\ntwo", newlines: newlines).map(\.text) == ["one\ntwo"])
    }
    #expect(parse("one<br>\ntwo").map(\.text) == ["one\n\ntwo"])
}

@Test func newlinesInContainersAreLineBreaksWithTheOption() {
    let list = parse("- one\n  two\n- three\nlazy")
    #expect(list.map(\.text) == ["one\ntwo", "three\nlazy"])
    #expect(list.map(\.marker) == [.bullet, .bullet])
    let quote = parse("> one\n> two\nlazy\n\n> > nested\n> > line")
    #expect(quote.map(\.text) == ["one\ntwo\nlazy", "nested\nline"])
    #expect(quote.map(\.containers) == [[.quote], [.quote, .quote]])
}

@Test func otherBlocksKeepTheirLinesWithTheOption() {
    #expect(parse("Title\nmore\n===\nnext").map(\.text) == ["Title\nmore", "next"])
    #expect(parse("Title\nmore\n===\nnext").first?.kind == .heading(level: 1))
    #expect(parse("# Title\nbody").map(\.text) == ["Title", "body"])
    #expect(parse("```\na\nb\n```").map(\.text) == ["a\nb"])
    #expect(parse("| a | b |\n| - | - |\n| 1 | 2 |").map(\.text) == ["a\tb\n1\t2"])
    #expect(parse("a | b\nnext").map(\.text) == ["a | b\nnext"])
    #expect(parse("$$\nx\ny").map(\.text) == ["$$\nx\ny"])
    #expect(parse("$$\nx = 1\n$$").first?.spans.first?.math?.tex == "x = 1")
}

@Test func inlineMarkupSpansLineBreaksWithTheOption() {
    let emphasis = parse("*one\ntwo* and **three\nfour**")[0]
    #expect(emphasis.text == "one\ntwo and three\nfour")
    #expect(emphasis.spans.map(\.range) == [0..<7, 12..<22])
    #expect(emphasis.spans.map(\.traits) == [.italic, .bold])
    let bold = parse("one\n**two**")[0]
    #expect(bold.text == "one\ntwo")
    #expect(bold.spans.map(\.range) == [4..<7])
    let link = parse("see [the\nguide](https://x.y) now")[0]
    #expect(link.text == "see the\nguide now")
    #expect(link.spans.first?.link == "https://x.y")
    #expect(parse("a <https://x.y>\nb")[0].spans.first?.link == "https://x.y")
    #expect(parse("a https://x.y\nb")[0].spans.first?.link == "https://x.y")
    #expect(parse("<b>one\ntwo</b>")[0].spans.map(\.range) == [0..<7])
}

/// A code span keeps the newline as a line break, as the rest of the
/// paragraph does.
@Test func codeSpanKeepsTheLineBreakWithTheOption() {
    let block = parse("a `b\nc` d")[0]
    #expect(block.text == "a b\nc d")
    #expect(block.spans.map(\.range) == [2..<5])
    #expect(block.spans.map(\.traits) == [.code])
    #expect(parse("a `b\nc` d", newlines: false)[0].text == "a b c d")
}

@Test func copiedTextHasTheLineBreaks() {
    let document = MarkdownStreamParser.document(from: "one\ntwo\n\n- item\n  more\n\n> quote\n> line",
                                                 newlinesAsLineBreaks: true)
    #expect(document.text(in: 0..<document.utf16Count) == "one\ntwo\nitem\nmore\nquote\nline")
    #expect(document.text(in: 2..<5) == "e\nt")
    #expect(document.copyText(in: 0..<document.utf16Count) == "one\ntwo\n\n- item\n  more\n\n> quote\n> line")
    let plain = MarkdownStreamParser.document(from: "one\ntwo")
    #expect(plain.copyText(in: 0..<plain.utf16Count) == "one two")
}

@MainActor
@Test func streamPassesTheOptionToItsParser() {
    let stream = TranscriptStream(markdown: "one\ntwo\n", newlinesAsLineBreaks: true)
    #expect(stream.document.blocks.map(\.text) == ["one\ntwo"])
    stream.append("three")
    stream.flush()
    #expect(stream.document.blocks.map(\.text) == ["one\ntwo\nthree"])
    let plain = TranscriptStream(markdown: "one\ntwo")
    #expect(plain.document.blocks.map(\.text) == ["one two"])
}


/// Each line of a paragraph only adds text at the end while it streams in:
/// the line break before it does not appear first as a space.
@Test func lineBreaksOnlyGrowTheTextWhileStreaming() {
    let markdown = "One line\nanother line\nand **a third\nwith bold** that\nends\n\n- item\n  more\n\n> quote\n> more"
    var parser = MarkdownStreamParser(idPrefix: "g", newlinesAsLineBreaks: true)
    var previous = parser.document
    var violations: [String] = []
    for character in markdown {
        parser.append(String(character))
        if !parser.document.extends(previous) {
            violations.append("\(previous.blocks.last?.text.debugDescription ?? "-") -> \(parser.document.blocks.last?.text.debugDescription ?? "-")")
        }
        previous = parser.document
    }
    #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))")
    parser.finish()
    #expect(parser.document.blocks.map(\.text) == ["One line\nanother line\nand a third\nwith bold that\nends", "item\nmore", "quote\nmore"])
}

/// A link destination after a line break is still read.
@Test func linkDestinationCanStartOnTheNextLine() {
    #expect(parse("[a](\nhttps://x.y)")[0].spans.first?.link == "https://x.y")
    #expect(parse("[a](https://x.y\n\"title\")")[0].spans.first?.link == "https://x.y")
    #expect(parse("[a](\nhttps://x.y)", newlines: false)[0].spans.first?.link == "https://x.y")
    #expect(parse("[a](\\\nhttps://x.y)", newlines: false)[0].spans.first?.link == "https://x.y")
}

/// Each line break starts a new laid-out line, and the paragraph grows
/// by one line per break.
@Test func lineBreaksLayOutAsLines() {
    let markdown = "one\ntwo\nthree"
    let spaces = DocumentLayout(document: MarkdownStreamParser.document(from: markdown), width: 300)
    let breaks = DocumentLayout(document: MarkdownStreamParser.document(from: markdown, newlinesAsLineBreaks: true),
                                width: 300)
    #expect(spaces.entry(at: 0).layout.lines.count == 1)
    #expect(breaks.entry(at: 0).layout.lines.count == 3)
    #expect(breaks.height > spaces.height)
}
