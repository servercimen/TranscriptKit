import Foundation
import Testing
@testable import TranscriptKit

private let sample = """
# Streaming *Markdown*

A paragraph with **bold**, *italic*, `inline code` and a [link](https://example.com/a_b).
It continues on a second line with snake_case and 2 * 3 * 4.

## Lists

- First item
- Second item with **bold**
  - Nested item
  - Another nested
- Third item

1. One
2. Two

- [ ] Open task
- [x] Done task with ~~old~~ new text

> A quote that
> spans two lines.
>
> > A nested quote.

1. A step with code:

   ```swift
   let y = 2
   ```

| Name | Value | Notes |
| :--- | ---: | :---: |
| alpha | 1 | **first** |
| beta | 22 | see https://example.com/x |

```swift
let x = **not bold**
print(x)
```

---

Final paragraph with ***both***, an <https://example.org> autolink, a bare www.example.net link, &copy; &#8212; &#x1F600; entities, <b>html bold</b><br>and ![a diagram](https://example.com/d.png) image.
"""

private func inline(_ source: String, open: Bool = false) -> InlineParser.Result {
    InlineParser.parse(source, open: open)
}

private func substring(_ result: InlineParser.Result, _ span: InlineSpan) -> String {
    (result.text as NSString).substring(with: NSRange(location: span.range.lowerBound, length: span.range.count))
}

// MARK: Inline

@Test func inlineEmphasisCodeAndLinks() {
    let result = inline("a **bold** and *it* with `code` and [text](https://x.y)")
    #expect(result.text == "a bold and it with code and text")
    let described = result.spans.map { "\(substring(result, $0)):\($0.traits.rawValue):\($0.link ?? "-")" }
    #expect(described == ["bold:1:-", "it:2:-", "code:4:-", "text:0:https://x.y"])
}

@Test func inlineNestedAndTripleDelimiters() {
    let nested = inline("**bold with *italic* inside**")
    #expect(nested.text == "bold with italic inside")
    #expect(nested.spans.contains { substring(nested, $0) == "italic" && $0.traits == .italic })
    #expect(nested.spans.contains { substring(nested, $0) == "bold with italic inside" && $0.traits == .bold })

    let triple = inline("***both***")
    #expect(triple.text == "both")
    #expect(triple.spans.map(\.traits) == [[.bold, .italic]])
}

@Test func inlineLeavesNonMarkupAlone() {
    #expect(inline("snake_case_name and 2 * 3 * 4").text == "snake_case_name and 2 * 3 * 4")
    #expect(inline("snake_case_name and 2 * 3 * 4").spans.isEmpty)
    #expect(inline("a \\*literal\\* star").text == "a *literal* star")
    #expect(inline("x &lt; y &amp;&amp; z").text == "x < y && z")
    #expect(inline("array[0] and [not a link]").text == "array[0] and [not a link]")
    #expect(inline("**unclosed and `unclosed").text == "**unclosed and `unclosed")
    #expect(inline("code keeps `**stars**` literal").text == "code keeps **stars** literal")
}

@Test func openInlineClosesMarkupAtTheEnd() {
    let bold = inline("Some **bol", open: true)
    #expect(bold.text == "Some bol")
    #expect(bold.spans == [InlineSpan(range: 5..<8, traits: .bold)])

    let code = inline("Run `swift te", open: true)
    #expect(code.text == "Run swift te")
    #expect(code.spans == [InlineSpan(range: 4..<12, traits: .code)])

    let link = inline("See [the docs](https://exam", open: true)
    #expect(link.text == "See the docs")
    #expect(link.spans.first?.range == 4..<12)
}

@Test func openInlineHoldsBackTrailingMarkup() {
    #expect(inline("Hello *", open: true).text == "Hello ")
    #expect(inline("Hello **bold*", open: true).text == "Hello bold")
    #expect(inline("Hello `", open: true).text == "Hello ")
    // A recent "[" hides what follows until the "]" and the character after it decide.
    #expect(inline("See [docs]", open: true).text == "See ")
    #expect(inline("See [", open: true).text == "See ")
}

// MARK: Blocks

@Test func parsesBlockStructure() {
    let document = MarkdownStreamParser.document(from: sample)
    let blocks = document.blocks
    typealias C = TranscriptBlock.Container
    let shape = blocks.map { block -> String in
        let kind: String
        switch block.kind {
        case .paragraph: kind = "p"
        case .heading(let level): kind = "h\(level)"
        case .code(let language): kind = "code:\(language ?? "-")"
        case .rule: kind = "hr"
        case .table(let table): kind = "table:\(table.columnCount)x\(table.rows.count)"
        }
        let containers = block.containers.map { $0 == .quote ? ">" : "li" }.joined(separator: "/")
        let marker: String
        switch block.marker {
        case nil: marker = ""
        case .bullet?: marker = " •"
        case .number(let number)?: marker = " " + number
        case .task(let checked)?: marker = checked ? " [x]" : " [ ]"
        }
        return containers.isEmpty ? kind + marker : "\(containers) \(kind)\(marker)"
    }
    #expect(shape == [
        "h1", "p", "h2",
        "li p •", "li p •", "li/li p •", "li/li p •", "li p •",
        "li p 1.", "li p 2.",
        "li p [ ]", "li p [x]",
        "> p", ">/> p",
        "li p 1.", "li code:swift",
        "table:3x3",
        "code:swift", "hr", "p",
    ])
    #expect(blocks[0].text == "Streaming Markdown")
    #expect(blocks[1].text.hasSuffix("second line with snake_case and 2 * 3 * 4."))
    #expect(blocks[11].text == "Done task with old new text")
    #expect(blocks[11].spans == [InlineSpan(range: 15..<18, traits: .strikethrough)])
    #expect(blocks[12].text == "A quote that spans two lines.")
    #expect(blocks[15].text == "let y = 2")
    #expect(blocks[16].text == "Name\tValue\tNotes\nalpha\t1\tfirst\nbeta\t22\tsee https://example.com/x")
    #expect(blocks[16].kind.table?.alignments == [.leading, .trailing, .center])
    #expect(blocks[17].text == "let x = **not bold**\nprint(x)")
    #expect(blocks[17].spans.isEmpty)
    #expect(blocks[19].text == "Final paragraph with both, an https://example.org autolink, a bare www.example.net link, © — 😀 entities, html bold\nand \u{FFFC} image.")
    #expect(blocks[19].spans.contains { $0.link == "http://www.example.net" })
    #expect(blocks[19].spans.last?.image == TranscriptImage(source: "https://example.com/d.png", alt: "a diagram"))
}

@Test func unclosedFenceStaysCode() {
    let document = MarkdownStreamParser.document(from: "```\nlet a = 1\n")
    #expect(document.blocks.map(\.kind) == [.code(language: nil)])
    #expect(document.blocks[0].text == "let a = 1")
}

// MARK: Streaming

/// Feeds `markdown` in chunks of `size` characters and returns every intermediate document.
private func stream(chunkSize size: Int, markdown: String = sample,
                    newlinesAsLineBreaks: Bool = false) -> (steps: [TranscriptDocument], final: TranscriptDocument) {
    var parser = MarkdownStreamParser(idPrefix: "md", newlinesAsLineBreaks: newlinesAsLineBreaks)
    var steps: [TranscriptDocument] = []
    var rest = Substring(markdown)
    while !rest.isEmpty {
        parser.append(String(rest.prefix(size)))
        rest = rest.dropFirst(size)
        steps.append(parser.document)
    }
    parser.finish()
    return (steps, parser.document)
}

@Test(arguments: [1, 2, 3, 7, 16])
func streamingMatchesOneShotParse(chunkSize: Int) {
    let expected = MarkdownStreamParser.document(from: sample)
    #expect(stream(chunkSize: chunkSize).final == expected)
}

@Test(arguments: [false, true])
func frozenBlocksNeverChange(newlinesAsLineBreaks: Bool) {
    let steps = stream(chunkSize: 1, newlinesAsLineBreaks: newlinesAsLineBreaks).steps
    for (previous, next) in zip(steps, steps.dropFirst()) {
        let settled = previous.blocks.dropLast()
        #expect(Array(next.blocks.prefix(settled.count)) == Array(settled))
    }
}

@Test(arguments: [false, true])
func displayedTextOnlyGrowsWhileStreaming(newlinesAsLineBreaks: Bool) {
    // Character by character is the worst case: every partial marker is seen.
    let steps = stream(chunkSize: 1, newlinesAsLineBreaks: newlinesAsLineBreaks).steps
    var violations: [String] = []
    for (previous, next) in zip(steps, steps.dropFirst()) where !next.extends(previous) {
        violations.append("\(previous.blocks.last.map { "\($0.kind) \($0.text.suffix(24))" } ?? "-")  ->  \(next.blocks.last.map { "\($0.kind) \($0.text.suffix(24))" } ?? "-")")
    }
    #expect(violations.isEmpty, "\(violations.count) steps rewrote visible text:\n\(violations.joined(separator: "\n"))")
}

@Test func blockMarkersAreHeldBackUntilResolved() {
    var parser = MarkdownStreamParser(idPrefix: "md")
    parser.append("Intro\n\n#")
    #expect(parser.document.blocks.count == 1)
    parser.append("# Title")
    #expect(parser.document.blocks.last?.kind == .heading(level: 2))

    parser.append("\n\n``")
    #expect(parser.document.blocks.count == 2)
    parser.append("`swift\nlet a = 1\n``")
    #expect(parser.document.blocks.last?.kind == .code(language: "swift"))
    #expect(parser.document.blocks.last?.text == "let a = 1")
    parser.append("`\n\nDone")
    #expect(parser.document.blocks.last?.text == "Done")
    #expect(parser.document.blocks.count == 4)
}

@Test func layoutAppliesInlineFontsAndListIndent() {
    let document = MarkdownStreamParser.document(from: "- item with **bold** text\n\nplain")
    let layout = DocumentLayout(document: document, width: 300)
    // The list item's text starts to the right of the paragraph's.
    #expect(layout.entry(at: 0).layout.lines[0].frame.minX > layout.entry(at: 1).layout.lines[0].frame.minX)
    #expect(layout.entry(at: 0).layout.marker != nil)
    #expect(layout.entry(at: 1).layout.marker == nil)
}

@Test func copyTextRestoresListMarkersAndBlockSpacing() {
    let document = MarkdownStreamParser.document(from: """
    Intro **bold**

    - one
      - nested
    2. two

    > quoted

    ---

    end
    """)
    #expect(document.copyText(in: 0..<document.utf16Count) == """
    Intro bold

    - one
      - nested
    2. two

    > quoted

    ---

    end
    """)
    // A selection that starts inside an item does not get that item's marker.
    let partial = document.copyText(in: 12..<document.utf16Count)
    #expect(partial.hasPrefix("ne\n  - nested"))
    #expect(document.copyText(in: 0..<5) == "Intro")
}

@Test func linkHitTestingFindsOnlyTheLinkGlyphs() {
    let document = MarkdownStreamParser.document(from: "Go to [the site](https://example.com) now")
    let layout = DocumentLayout(document: document, width: 400)
    let linkRect = layout.selectionRects(for: 6..<14)[0]
    #expect(layout.link(at: CGPoint(x: linkRect.midX, y: linkRect.midY)) == "https://example.com")
    #expect(layout.link(at: CGPoint(x: linkRect.minX + 1, y: linkRect.midY)) == "https://example.com")
    #expect(layout.link(at: CGPoint(x: linkRect.maxX - 1, y: linkRect.midY)) == "https://example.com")
    #expect(layout.link(at: CGPoint(x: linkRect.minX - 3, y: linkRect.midY)) == nil)
    #expect(layout.link(at: CGPoint(x: linkRect.maxX + 3, y: linkRect.midY)) == nil)
    #expect(layout.link(at: CGPoint(x: 390, y: linkRect.midY)) == nil)
}

@Test(arguments: [1, 5])
func incrementalLayoutMatchesFreshLayout(chunkSize: Int) {
    // Lay out every intermediate document twice: reusing the previous layout
    // (as the view does) and from scratch. Lines and geometry must agree.
    var previous: DocumentLayout?
    for document in stream(chunkSize: chunkSize).steps {
        let incremental = DocumentLayout(document: document, width: 320, reusing: previous)
        let fresh = DocumentLayout(document: document, width: 320)
        #expect(incremental.height == fresh.height)
        #expect(incremental.length == fresh.length)
        for (a, b) in zip((0..<incremental.entryCount).map(incremental.entry(at:)), (0..<fresh.entryCount).map(fresh.entry(at:))) {
            #expect(a.y == b.y)
            #expect(a.layout.lines.map(\.range) == b.layout.lines.map(\.range), "block \(a.layout.block.id)")
            // Widths can differ in the last floating-point digit depending on
            // which string a line was typeset from.
            for (x, y) in zip(a.layout.lines, b.layout.lines) {
                let close = abs(x.frame.minX - y.frame.minX) < 0.001 && abs(x.frame.minY - y.frame.minY) < 0.001
                    && abs(x.frame.width - y.frame.width) < 0.001 && abs(x.frame.height - y.frame.height) < 0.001
                #expect(close, "block \(a.layout.block.id) line \(x.range): \(x.frame) vs \(y.frame)")
            }
        }
        // Geometry queries go through the per-line index base.
        let probe = max(fresh.length - 3, 0)
        #expect(abs(incremental.caretRect(at: probe).minX - fresh.caretRect(at: probe).minX) < 0.001)
        #expect(incremental.caretRect(at: probe).minY == fresh.caretRect(at: probe).minY)
        let point = CGPoint(x: fresh.caretRect(at: probe).midX, y: fresh.caretRect(at: probe).midY)
        #expect(incremental.closestOffset(to: point) == fresh.closestOffset(to: point))
        previous = incremental
    }
}
