import CoreGraphics
import Foundation
import Testing
@testable import TranscriptKit

private func blocks(_ markdown: String) -> [TranscriptBlock] {
    MarkdownStreamParser.document(from: markdown).blocks
}

private func inline(_ source: String, open: Bool = false) -> InlineParser.Result {
    InlineParser.parse(source, open: open)
}

private func spanned(_ result: InlineParser.Result) -> [String] {
    result.spans.map { span in
        let text = (result.text as NSString).substring(with: NSRange(location: span.range.lowerBound, length: span.range.count))
        return "\(text):\(span.traits.rawValue):\(span.link ?? "-")"
    }
}

/// Every intermediate document of `markdown` fed one character at a time.
private func characterSteps(_ markdown: String) -> [TranscriptDocument] {
    var parser = MarkdownStreamParser(idPrefix: "s")
    var steps: [TranscriptDocument] = []
    for character in markdown {
        parser.append(String(character))
        steps.append(parser.document)
    }
    parser.finish()
    steps.append(parser.document)
    return steps
}

// MARK: Blocks

@Test func setextHeadings() {
    let result = blocks("Title\n===\n\nSub title\n---\n\nfoo\n-")
    #expect(result.map(\.kind) == [.heading(level: 1), .heading(level: 2), .heading(level: 2)])
    #expect(result.map(\.text) == ["Title", "Sub title", "foo"])
    // After a blank line, "---" is a rule.
    #expect(blocks("Para\n\n---").map(\.kind) == [.paragraph, .rule])
}

@Test func indentedCode() {
    let result = blocks("    let a = 1\n\n    let b = 2\n\nText")
    #expect(result.map(\.kind) == [.code(language: nil), .paragraph])
    #expect(result[0].text == "let a = 1\n\nlet b = 2")
    // Indentation inside a paragraph is not code.
    #expect(blocks("para\n    not code").map(\.text) == ["para not code"])
}

@Test func containersNest() {
    let result = blocks("> quoted\nlazy line\n>\n> > nested\n\n- item\n\n  more of the item\n  > quote in item\n- next")
    #expect(result.map(\.text) == ["quoted lazy line", "nested", "item", "more of the item", "quote in item", "next"])
    #expect(result.map(\.containers) == [[.quote], [.quote, .quote], [.listItem], [.listItem], [.listItem, .quote], [.listItem]])
    #expect(result.map(\.marker) == [nil, nil, .bullet, nil, nil, .bullet])
}

@Test func listItemsInterruptParagraphsOnlyWhenTheyCan() {
    #expect(blocks("The year was\n2024. It rained.").count == 1)
    #expect(blocks("Steps:\n1. one\n2. two").map(\.marker) == [nil, .number("1."), .number("2.")])
    #expect(blocks("Items:\n- a").map(\.marker) == [nil, .bullet])
    #expect(blocks("3) third").map(\.marker) == [.number("3)")])
}

@Test func listItemsAreNumberedLikeCommonMark() {
    #expect(blocks("1. a\n1. b\n1. c").map(\.marker) == [.number("1."), .number("2."), .number("3.")])
    #expect(blocks("3. a\n3. b").map(\.marker) == [.number("3."), .number("4.")])
    // Another delimiter, or a paragraph in between, starts a new list.
    #expect(blocks("1. a\n1) b").map(\.marker) == [.number("1."), .number("1)")])
    #expect(blocks("1. a\n\npara\n\n1. b").map(\.marker) == [.number("1."), nil, .number("1.")])
    #expect(blocks("1. a\n<!-- c -->\n1. b").map(\.marker) == [.number("1."), .number("1.")])
    // Blank lines and content inside items keep a list going; nested lists count on their own.
    #expect(blocks("1. a\n\n   more\n\n   1. x\n   1. y\n1. b\n   1. z").map(\.marker)
        == [.number("1."), nil, .number("1."), .number("2."), .number("2."), .number("1.")])
    // A quote between items ends the list.
    #expect(blocks("1. a\n> q\n1. b").map(\.marker) == [.number("1."), nil, .number("1.")])
    // Only a list that starts at 1 interrupts a paragraph, whatever it would be numbered.
    #expect(blocks("1. a\n\nText\n2. not an item").count == 2)
}

@Test func taskLists() {
    let result = blocks("- [ ] open\n- [x] done\n- [X] also done\n- [y] not a task")
    #expect(result.map(\.marker) == [.task(checked: false), .task(checked: true), .task(checked: true), .bullet])
    #expect(result.map(\.text) == ["open", "done", "also done", "[y] not a task"])
}

@Test func htmlCommentBlocksAreHidden() {
    #expect(blocks("a\n\n<!-- hidden\nstill hidden -->\n\nb").map(\.text) == ["a", "b"])
    #expect(blocks("<!-- one line -->\nshown").map(\.text) == ["shown"])
}

@Test func tables() throws {
    let result = blocks("| a | b |\n| --- | :-: |\n| 1 | 2 | extra |\n| only |\n\nafter")
    let table = try #require(result.first?.kind.table)
    #expect(table.alignments == [.leading, .center])
    #expect(result[0].text == "a\tb\n1\t2\nonly\t")
    #expect(table.rows == [[0..<1, 2..<3], [4..<5, 6..<7], [8..<12, 13..<13]])
    #expect(result[1].text == "after")

    // Without outer pipes, and with an escaped pipe in a cell.
    let bare = blocks("x | y\n--|--\n`a\\|b` | **c**")
    #expect(bare.count == 1)
    #expect(bare[0].text == "x\ty\na|b\tc")
    #expect(bare[0].spans == [InlineSpan(range: 4..<7, traits: .code), InlineSpan(range: 8..<9, traits: .bold)])

    // A delimiter row with the wrong number of cells makes no table.
    #expect(blocks("| a | b |\n| --- |").map(\.kind) == [.paragraph])
}

@Test func tableHeaderWaitsForItsDelimiterRow() {
    var parser = MarkdownStreamParser(idPrefix: "t")
    parser.append("Intro\n\n| a | b |\n")
    #expect(parser.document.blocks.map(\.text) == ["Intro"])
    parser.append("| - | - |\n| 1")
    #expect(parser.document.blocks.last?.text == "a\tb\n1")
    parser.append(" | 2 |\n")
    #expect(parser.document.blocks.last?.text == "a\tb\n1\t2")
    // A line of pipes that is not followed by a delimiter row shows as text.
    var other = MarkdownStreamParser(idPrefix: "o")
    other.append("| not a table |\njust text\n")
    #expect(other.document.blocks.map(\.text) == ["| not a table | just text"])
}

@Test(arguments: [
    "| Name | Score |\n| --- | ---: |\n| **Ann** | 10 |\n| Bo | 7 |\n| Cy | see https://example.com |\n",
    "- [ ] task one\n- [x] task *two*\n  - nested ~~old~~ new\n\n> quote\n>\n> > deeper &amp; deeper\n\n1. step\n\n   ```\n   code\n   ```\n",
    "A <b>bold</b> and <i>it</i><br>next &#169; &copy; ![pic](https://x.y/p.png) www.example.com.\n",
    "Write to first_last@example.co.uk or <ops+x@example.org>, not @handle.\n\n1. a\n1. b\n\n3) c\n3) d\n",
    "See [the docs][d] and [d][], as in [1] and [2].\n\n[d]: https://docs.example.com \"Docs\"\n[1]: <https://one.example>\n\nAfter, [a long bracket that is not a link at all, just an aside in the text] and [x](https://x.y).\n",
])
func newElementsOnlyGrowWhileStreaming(markdown: String) {
    let steps = characterSteps(markdown)
    var violations: [String] = []
    for (previous, next) in zip(steps, steps.dropFirst().dropLast()) where !next.extends(previous) {
        violations.append("\(previous.blocks.last?.text.debugDescription ?? "-") -> \(next.blocks.last?.text.debugDescription ?? "-")")
    }
    #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))")
    #expect(steps.last == MarkdownStreamParser.document(from: markdown, idPrefix: "s"))
}

// MARK: Inline

@Test func strikethrough() {
    #expect(spanned(inline("a ~~gone~~ b")) == ["gone:8:-"])
    #expect(inline("~5 min and ~10 min").spans.isEmpty)
    #expect(inline("~5 min and ~10 min").text == "~5 min and ~10 min")
    #expect(inline("~~~not~~~").spans.isEmpty)
}

@Test func entities() {
    #expect(inline("&#65;&#x42;&copy;&rarr;&bogus;&#;").text == "AB©→&bogus;&#;")
    #expect(inline("&#0; &#1114112;").text == "\u{FFFD} \u{FFFD}")
    #expect(inline("AT&T and R&D").text == "AT&T and R&D")
    #expect(inline("x &#x1F60", open: true).text == "x ")
    // HTML's whole list, including names whose value is two scalars.
    #expect(inline("&Ccedil;&frac13;&NotEqualTilde;&CounterClockwiseContourIntegral;").text == "Ç⅓\u{2242}\u{338}∳")
    #expect(inline("&ccedil", open: true).text == "")
    #expect(inline("&ccedilx", open: true).text == "&ccedilx")
    #expect(HTMLEntities.values.count == 2125)
}

@Test func inlineHTML() {
    #expect(inline("x<br>y<br/>z<br />w").text == "x\ny\nz\nw")
    #expect(spanned(inline("<b>bold</b> <em>it</em> <u>under</u> <del>old</del> <kbd>K</kbd>"))
        == ["bold:1:-", "it:2:-", "under:16:-", "old:8:-", "K:4:-"])
    #expect(inline("a <span>b</span> c").text == "a <span>b</span> c")
    #expect(inline("a<!-- hidden -->b").text == "ab")
    #expect(inline("if a < b and c > d").text == "if a < b and c > d")
    // An unclosed tag styles the rest; a stray closing tag is dropped.
    #expect(spanned(inline("<b>rest")) == ["rest:1:-"])
    #expect(inline("text</i>").text == "text")
    // Partial tags and comments are hidden while streaming.
    #expect(inline("a <b", open: true).text == "a ")
    #expect(inline("a <!-- not yet", open: true).text == "a ")
}

@Test func bareURLs() {
    #expect(spanned(inline("see https://a.com/x.")) == ["https://a.com/x:0:https://a.com/x"])
    #expect(spanned(inline("(at https://a.com/(b))")) == ["https://a.com/(b):0:https://a.com/(b)"])
    #expect(spanned(inline("visit www.a.com, now")) == ["www.a.com:0:http://www.a.com"])
    #expect(spanned(inline("**https://a.com/a_b_c**")) == ["https://a.com/a_b_c:0:https://a.com/a_b_c", "https://a.com/a_b_c:1:-"])
    #expect(inline("xhttps://a.com").spans.isEmpty)
    #expect(inline("https:// alone").spans.isEmpty)
    #expect(spanned(inline("[https://a.com](https://b.com)")) == ["https://a.com:0:https://b.com"])
    #expect(spanned(inline("at https://a.com/x&quot;")) == ["https://a.com/x:0:https://a.com/x"])
}

@Test func emailAddresses() {
    #expect(spanned(inline("Mail support@example.com or <a.b+c@ex-ample.co.uk> now."))
        == ["support@example.com:0:mailto:support@example.com", "a.b+c@ex-ample.co.uk:0:mailto:a.b+c@ex-ample.co.uk"])
    #expect(spanned(inline("first_last@ex.co.uk.")) == ["first_last@ex.co.uk:0:mailto:first_last@ex.co.uk"])
    // A domain needs a dot and may not end in "-" or "_"; a handle is not an address.
    #expect(inline("a@b and a@b.c_ and @handle").spans.isEmpty)
    // Angle brackets follow CommonMark, which needs no dot.
    #expect(spanned(inline("<root@localhost>")) == ["root@localhost:0:mailto:root@localhost"])
    // Not inside link text or code.
    #expect(spanned(inline("[a@b.com](https://x.y) `c@d.com`")) == ["a@b.com:0:https://x.y", "c@d.com:4:-"])
    // While streaming, an address is a link once it is one, and grows.
    #expect(spanned(inline("at me@ex.co", open: true)) == ["me@ex.co:0:mailto:me@ex.co"])
    #expect(inline("at <me@ex", open: true).text == "at ")
}

@Test func referenceLinks() throws {
    let document = MarkdownStreamParser.document(from: """
    See [the docs][d], [D][] and [1]; [x][nope] and array[0].

    [d]: https://docs.example.com "Title"
    [1]: <https://one.example.com>
    [d]: https://ignored.example.com
    """)
    #expect(document.count == 1)
    let block = document.block(at: 0)
    #expect(block.text == "See the docs, D and [1]; x and array[0].")
    #expect(document.linkDefinitions == ["d": "https://docs.example.com", "1": "https://one.example.com"])
    let references = block.spans.compactMap { span -> String? in
        guard let label = span.reference else { return nil }
        let text = (block.text as NSString).substring(with: NSRange(location: span.range.lowerBound, length: span.range.count))
        return "\(text)>\(label)>\(document.destination(of: span) ?? "-")"
    }
    #expect(references == ["the docs>d>https://docs.example.com", "D>d>https://docs.example.com",
                           "[1]>1>https://one.example.com", "x>nope>-", "[0]>0>-"])
    // Labels match without regard to case or runs of whitespace.
    let spaced = MarkdownStreamParser.document(from: "[Foo  Bar][]\n\n[foo bar]: /u")
    #expect(spaced.destination(of: try #require(spaced.block(at: 0).spans.first)) == "/u")
}

@Test func linkDefinitionsFollowTheirRules() {
    // A definition cannot interrupt a paragraph.
    #expect(blocks("para\n[a]: /u").map(\.text) == ["para [a]: /u"])
    // Without a destination, or with something after it that is not a title, it is text.
    #expect(blocks("[a]:\n\n[b]: /u junk").map(\.text) == ["[a]:", "[b]: /u junk"])
    #expect(MarkdownStreamParser.document(from: "[c]: /u 'title'\n[e]: /v (title)").linkDefinitions == ["c": "/u", "e": "/v"])
    // Inside a code block it is code; in a list item it still defines.
    #expect(blocks("```\n[a]: /u\n```").map(\.text) == ["[a]: /u"])
    #expect(MarkdownStreamParser.document(from: "- [a]: /u").linkDefinitions == ["a": "/u"])
    // Right under an item's text it continues that paragraph; on its own it ends the list.
    #expect(blocks("1. a\n[x]: /u\n1. b").map(\.text) == ["a [x]: /u", "b"])
    #expect(blocks("1. a\n\n[x]: /u\n\n1. b").map(\.marker) == [.number("1."), .number("1.")])
}

@Test func definitionLinesNeverShowWhileStreaming() {
    var parser = MarkdownStreamParser(idPrefix: "d")
    parser.append("Text [a].\n\n")
    for character in "[a]: https://a.example \"A\"" {
        parser.append(String(character))
        #expect(parser.document.blocks.map(\.text) == ["Text [a]."])
    }
    parser.append("\n")
    #expect(parser.document.linkDefinitions == ["a": "https://a.example"])
    // A line that only starts like one shows once it is clearly not one.
    parser.append("[b] is text")
    #expect(parser.document.blocks.last?.text == "[b] is text")
}

@Test func referencesBecomeLinksWhenTheirDefinitionArrives() throws {
    var parser = MarkdownStreamParser(idPrefix: "r")
    parser.append("Read [the guide][g] first.\n\nMore text here.\n\n")
    let before = DocumentLayout(document: parser.document, width: 320)
    let rect = try #require(before.selectionRects(for: 5..<14).first)
    let point = CGPoint(x: rect.midX, y: rect.midY)
    #expect(before.link(at: point) == nil)
    parser.append("[g]: https://guide.example\n")
    let after = DocumentLayout(document: parser.document, width: 320, reusing: before)
    #expect(after.document.extends(before.document))
    #expect(after.link(at: point) == "https://guide.example")
    // The paragraph above is laid out again to style its link, and reported
    // as restyled in place: only it is redrawn, not everything below it.
    #expect(after.entry(at: 0).layout !== before.entry(at: 0).layout)
    #expect(after.entry(at: 1).layout === before.entry(at: 1).layout)
    let changes = after.changes(since: before)
    // With the margin tags' shapes may draw into.
    #expect(changes.restyled == [after.entry(at: 0).frame.insetBy(dx: 0, dy: -TranscriptPath.maximumOverhang)])
    #expect(changes.top >= after.entry(at: 1).frame.maxY)
}

@Test func images() {
    let image = inline("an ![a *nice* pic](https://x.y/p.png \"title\") here")
    #expect(image.text == "an \u{FFFC} here")
    #expect(image.spans == [InlineSpan(range: 3..<4, image: TranscriptImage(source: "https://x.y/p.png", alt: "a nice pic"))])
    // Not an image: the "!" stays.
    #expect(inline("![alt] text").text == "![alt] text")
    // Nothing of an image shows until it is complete.
    #expect(inline("an ![al", open: true).text == "an ")
    #expect(inline("an ![alt](https://x", open: true).text == "an ")
    #expect(inline("an ![alt](u) b", open: true).text == "an \u{FFFC} b")
    // An image inside a link.
    let linked = inline("[![logo](l.png)](https://site)")
    #expect(linked.text == "\u{FFFC}")
    #expect(linked.spans.contains { $0.link == "https://site" })
}

// MARK: Copy

@Test func copyTextWritesNewElementsAsMarkdown() {
    let document = MarkdownStreamParser.document(from: "- [ ] open\n- [x] done\n\n> outer\n>\n> > inner\n\n| a | b |\n| :- | -: |\n| 1 | 2 |\n\nan ![alt text](u.png) image")
    #expect(document.copyText(in: 0..<document.utf16Count) == """
    - [ ] open
    - [x] done

    > outer

    > > inner

    | a | b |
    | --- | ---: |
    | 1 | 2 |

    an alt text image
    """)
}

// MARK: Layout

@Test func tableLayoutFitsAndHitTestsCells() throws {
    let document = MarkdownStreamParser.document(from: """
    | Short | A much longer column that has to wrap onto several lines | n |
    | --- | --- | ---: |
    | a | words words words words words words words words words words | 1 |
    | bb | x | 22 |
    """)
    let layout = DocumentLayout(document: document, width: 300)
    let entry = layout.entry(at: 0)
    let table = try #require(entry.layout.table)
    #expect(table.columnX.count == 4)
    #expect(table.columnX.last! <= 300.5)
    #expect(table.rowY.count == 4)
    // The wide column wraps, so its rows are taller than one line.
    #expect(table.rowY[2] - table.rowY[1] > table.rowY[3] - table.rowY[2])
    // Each cell's lines stay inside the cell.
    for (row, cells) in table.cellLines.enumerated() {
        for (column, lines) in cells.enumerated() {
            for index in lines {
                let frame = entry.layout.lines[index].frame
                #expect(frame.minX >= table.columnX[column] - 0.5 && frame.maxX <= table.columnX[column + 1] + 0.5)
                #expect(frame.minY >= table.rowY[row] && frame.maxY <= table.rowY[row + 1] + 0.5)
            }
        }
    }
    // A tap in a cell lands in that cell's text.
    let cells = try #require(document.block(at: 0).kind.table).rows
    let point = CGPoint(x: (table.columnX[0] + table.columnX[1]) / 2, y: (table.rowY[2] + table.rowY[3]) / 2)
    #expect(cells[2][0].contains(layout.closestOffset(to: point)) || cells[2][0].upperBound == layout.closestOffset(to: point))
    // Trailing alignment puts the number at the right of its column.
    let numberLine = entry.layout.lines[table.cellLines[2][2].lowerBound]
    #expect(abs(numberLine.frame.maxX - (table.columnX[3] - entry.layout.style.tableCellPadding)) < 1)
}

@Test func aLongCellDoesNotSqueezeShortColumns() throws {
    let document = MarkdownStreamParser.document(from: """
    | Option | Main thread | Notes |
    | :--- | ---: | :--- |
    | Native views with a much longer explanation in this cell that wraps onto several lines | 3.1 s | another process |
    | Tail strip | 1.6 s | off the main thread |
    """)
    let layout = DocumentLayout(document: document, width: 340)
    let block = layout.entry(at: 0).layout
    let table = try #require(block.table)
    #expect(table.columnX.last! <= 340.5)
    // No word in the short columns is broken: each of their lines ends at a space or the cell's end.
    let text = document.block(at: 0).text as NSString
    for row in table.cellLines {
        for (column, lines) in row.enumerated() where column > 0 {
            for index in lines.dropLast() {
                let end = block.lines[index].range.upperBound
                #expect(text.character(at: end - 1) == 0x20, "column \(column) broke a word")
            }
        }
    }
    // "1.6 s" fits on one line.
    #expect(table.cellLines[2][1].count == 1)
}

@Test func containersIndentAndMarkersMatchTheirKind() {
    let document = MarkdownStreamParser.document(from: "- [x] done\n- bullet\n\n> > deep")
    let layout = DocumentLayout(document: document, width: 300)
    let style = TranscriptStyle()
    if case .checkbox(_, let checked)? = layout.entry(at: 0).layout.marker {
        #expect(checked)
    } else {
        Issue.record("A task has a checkbox")
    }
    if case .text? = layout.entry(at: 1).layout.marker {} else { Issue.record("A bullet is drawn as text") }
    #expect(layout.entry(at: 2).layout.lines[0].frame.minX == style.quoteIndent * 2)
    #expect(layout.entry(at: 1).y - layout.entry(at: 0).frame.maxY == style.listItemSpacing)
}

@Test func imagesShowTheirAltTextUntilAPictureArrives() async throws {
    let document = MarkdownStreamParser.document(from: "see ![a chart](https://x.y/c.png) here")
    let store = TranscriptImageStore()
    let before = DocumentLayout(document: document, width: 300, style: TranscriptStyle(), reusing: nil, images: store)
    let placeholder = try #require(before.entry(at: 0).layout.attachments.first)
    #expect(placeholder.attachment.picture == nil)
    #expect(placeholder.attachment.label != nil)

    // A loader is only used once set; then the picture arrives and the block is laid out again.
    let arrived = AsyncStream<Void>.makeStream()
    store.setLoader({ _ in
        let context = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()
    }, onChange: { arrived.continuation.yield() })
    _ = DocumentLayout(document: document, width: 300, style: TranscriptStyle(), reusing: before, images: store)
    for await _ in arrived.stream { break }
    let after = DocumentLayout(document: document, width: 300, style: TranscriptStyle(), reusing: before, images: store)
    let shown = try #require(after.entry(at: 0).layout.attachments.first)
    #expect(shown.attachment.picture != nil)
    #expect(shown.rect.size == CGSize(width: 40, height: 20))
    #expect(after.entry(at: 0).layout !== before.entry(at: 0).layout)
}
