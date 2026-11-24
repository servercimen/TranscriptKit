import Foundation
import Testing
@testable import TranscriptKit

/// Markdown with the constructs that are hard to parse incrementally: markup
/// whose meaning depends on later characters, a lone `<`, entities, images,
/// escapes, hard breaks, surrogate pairs and unclosed markup at the end.
let trickyMarkdown = """
# Heading with `code` and a trailing \\
Paragraph with a < b and c > d, &amp; entities &lt;tag&gt; and &am partial.
An image ![alt text](https://img.example/a.png) and an escaped \\![not image].
Snake_case_words, *emphasis _mixed* here_, **strong *nested* text**, ***all three***.
A hard break with backslash\\
and two spaces
next line. Autolink <https://example.com/x?y=1> and <notalink and <ab:cd.
Mail support@example.com, first_last@ex.co.uk or <a+b@x.org>; not @handles or a@b.
See [the guide][g], [g][] and citation [1] or array[0].

[g]: https://guide.example "Guide"
[1]: <https://one.example>
Unicode: café, 日本語, emoji 👩‍💻 and 🇺🇸 flags, *émphasis* and `code 🎉`.

- item with `code` and [link](https://x.y/(paren))
  - nested *item*
1. ordered **bold**

> quote line one
> quote line two with **bold

```swift
let x = "a < b" // ** not bold **
```

Trailing paragraph with an unclosed `code span and *emphasis
"""

/// Paragraphs whose lines end in a single newline, as models write them,
/// next to hard breaks and to lines that could start another block.
/// Written with explicit "\n" so that the trailing spaces stay.
let lineBreakMarkdown = "First line\nsecond line  \nthird line\\\nfourth line \nfifth\t\n**bold** start\n"
    + "a <b\n    >tag</b\n    > over lines, a break<br>\nafter it<br />\\\nand <br\n/> inside\n"
    + "`code\nspan` and [link\ntext](\nhttps://x.y) and *emphasis\nover lines*\r\nCRLF line\r\n\n"
    + "- item one\n  continued\nlazy line\n- item two\n\n> quote one\n> quote two\nlazy quote\n\n"
    + "Setext title\nover two lines\n===\n\nA | B\nnot a table\n\n| a | b |\n| - | - |\n| 1 | 2 |\n\n"
    + "$$\nx = 1\ny = 2\n\nafter math\n1. one\n   two\n\n```\ncode\nlines\n```\nlast line\nends here"

/// The benchmark's answer text (Benchmark/TranscriptBench/Corpus.swift).
func answerSection(_ index: Int) -> String {
    """
    ## Step \(index): caching the layout

    The renderer keeps **one layout per block** and reuses it while the *last block* grows. \
    When a chunk arrives, only `block \(index)` is measured again, so the cost of an update \
    does not depend on how long the conversation already is. See the \
    [design notes](https://example.com/notes/\(index)) for the details.

    A second paragraph adds some plain prose so that the text wraps over several lines on a \
    phone screen, which is what a real answer looks like most of the time.

    - First point about item \(index) with `inline code`
    - Second point with **strong emphasis** in the middle
      - A nested point that explains the second one
    - Third point, a little longer than the others so that it wraps onto another line

    ```swift
    func update\(index)(_ chunk: String) {
        parser.append(chunk)
        view.document = parser.document
        log("updated \(index)")
    }
    ```

    1. Measure the block
    2. Draw what is visible
    3. Repeat for the next chunk


    """
}

/// A small deterministic generator, so failures reproduce.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

/// Chunk sizes: fixed, or random between 1 and 12.
private func chunks(of text: String, size: Int?, seed: UInt64 = 1) -> [String] {
    var generator = SeededGenerator(state: seed)
    var result: [String] = []
    var rest = Substring(text)
    while !rest.isEmpty {
        let length = size ?? Int.random(in: 1...12, using: &generator)
        result.append(String(rest.prefix(length)))
        rest = rest.dropFirst(length)
    }
    return result
}

@Test(arguments: [1, 2, 3, 5, 7, 13, nil] as [Int?], [false, true])
func incrementalParseMatchesParsingFromScratch(chunkSize: Int?, newlinesAsLineBreaks: Bool) {
    for markdown in [trickyMarkdown, (1...3).map(answerSection).joined(), lineBreakMarkdown] {
        var parser = MarkdownStreamParser(idPrefix: "md", newlinesAsLineBreaks: newlinesAsLineBreaks)
        var sent = ""
        var mismatches: [String] = []
        for chunk in chunks(of: markdown, size: chunkSize, seed: 7) {
            parser.append(chunk)
            sent += chunk
            var fresh = MarkdownStreamParser(idPrefix: "md", newlinesAsLineBreaks: newlinesAsLineBreaks)
            fresh.append(sent)
            if parser.document != fresh.document, mismatches.count < 5 {
                mismatches.append("after \(sent.count) characters: \(describe(parser.document.blocks.last)) vs \(describe(fresh.document.blocks.last))")
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.joined(separator: "\n"))")
        parser.finish()
        #expect(parser.document == MarkdownStreamParser.document(from: markdown, newlinesAsLineBreaks: newlinesAsLineBreaks))
    }
}

private func describe(_ block: TranscriptBlock?) -> String {
    guard let block else { return "-" }
    return "\(block.kind) \"\(block.text.suffix(40))\" \(block.spans)"
}

/// Random inline Markdown, heavy on markup characters.
private func randomInline(length: Int, using generator: inout SeededGenerator) -> String {
    let pieces = ["a", "b", " ", "*", "**", "_", "`", "``", "\\", "[", "]", "(", ")", "!", "<", ">", "&", "amp;",
                  "lt", ";", "http:", "//x", "é", "e\u{301}", "👩‍💻", "🇺🇸", "日", "\t", "x_y", "*a*", "[l](u)",
                  "@", ".", "-", "+", "ex.com", "a.b@c.d", "mail@x"]
    var result = ""
    while result.count < length { result += pieces.randomElement(using: &generator)! }
    return result
}

/// The inline parser resumed from a checkpoint after every unit gives the
/// same result as parsing each prefix from scratch.
@Test func resumedInlineParseMatchesParsingFromScratch() {
    var generator = SeededGenerator(state: 42)
    var failures: [String] = []
    for _ in 0..<300 {
        let source = randomInline(length: 40, using: &generator)
        let units = Array(source.utf16)
        var checkpoint = InlineParser.Checkpoint()
        for end in 1...units.count {
            let prefix = Array(units[..<end])
            // A trailing backslash or space may be rewritten by a hard break.
            var stable = prefix.count
            while stable > 0, [0x20, 0x09, 0x5C].contains(prefix[stable - 1]) { stable -= 1 }
            let resumed = InlineParser.parse(prefix, open: true, stableLength: stable, resumingFrom: &checkpoint)
            var fresh = InlineParser.Checkpoint()
            let expected = InlineParser.parse(prefix, open: true, stableLength: 0, resumingFrom: &fresh)
            if resumed != expected, failures.count < 5 {
                failures.append("\(String(decoding: prefix, as: UTF16.self).debugDescription): \(resumed) vs \(expected)")
            }
        }
        var final = checkpoint
        let finished = InlineParser.parse(units, open: false, stableLength: units.count, resumingFrom: &final)
        if finished != InlineParser.parse(source, open: false), failures.count < 5 {
            failures.append("final \(source.debugDescription)")
        }
    }
    #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
}

/// Text shown while streaming only grows at its end, for random inline input
/// typed one unit at a time.
@Test func openInlineTextOnlyGrows() {
    // Known exceptions, where text shown speculatively is restored as
    // literal text once it turns out not to be markup: an autolink that gets
    // a space, and an opener inside an unclosed span of the other kind
    // (`*a _b* c`). The view treats those updates as replacements.
    // Everything else must only grow, brackets included: these sources are
    // shorter than the reach of an open "[".
    var generator = SeededGenerator(state: 9)
    var failures: [String] = []
    var tested = 0
    while tested < 300 {
        let source = randomInline(length: 30, using: &generator)
        if source.contains("<") || (source.contains("*") && source.contains("_")) { continue }
        tested += 1
        var previous = ""
        var prefix = ""
        for character in source {
            prefix.append(character)
            let text = InlineParser.parse(prefix, open: true).text
            if !text.hasPrefix(previous), failures.count < 8 {
                failures.append("\(prefix.debugDescription): \(previous.debugDescription) -> \(text.debugDescription)")
            }
            previous = text
        }
    }
    #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
}

/// A stray `<` must not keep the rest of the paragraph undecided, or every
/// update would parse the whole paragraph again.
@Test func checkpointKeepsUpWithLongParagraphs() {
    for opener in ["a < b ", "x &unknown; ", "see ![", "1 * 2 ", "[not a link] ", "<ab ", "`never closed "] {
        let source = Array((opener + String(repeating: "word ", count: 400)).utf16)
        var checkpoint = InlineParser.Checkpoint()
        var end = 0
        while end < source.count {
            end = min(end + 7, source.count)
            _ = InlineParser.parse(Array(source[..<end]), open: true, stableLength: end, resumingFrom: &checkpoint)
        }
        let behind = source.count - checkpoint.position
        // An unclosed code span really is undecided until it closes.
        if opener.hasPrefix("`") {
            #expect(behind > 1000)
        } else {
            #expect(behind < 10, "\(opener.debugDescription) left the checkpoint \(behind) units behind")
        }
    }
}

@Test func entitiesAndImagesDoNotShrinkWhileStreaming() {
    #expect(InlineParser.parse("Tom &am", open: true).text == "Tom ")
    #expect(InlineParser.parse("Tom &amp", open: true).text == "Tom ")
    #expect(InlineParser.parse("Tom &amp;", open: true).text == "Tom &")
    #expect(InlineParser.parse("Tom &amx", open: true).text == "Tom &amx")
    #expect(InlineParser.parse("Hello!", open: true).text == "Hello")
    #expect(InlineParser.parse("Hello!", open: false).text == "Hello!")
    #expect(InlineParser.parse("Hello! ", open: true).text == "Hello! ")
    #expect(InlineParser.parse("an ![image](u)", open: false).text == "an \u{FFFC}")
    // An escaped "!" before a link is text, not an image marker.
    #expect(InlineParser.parse("\\![link](u)", open: false).text == "!link")
}

/// A first line that has not ended yet resumes its inline parse from the
/// last update's checkpoint; it must still match a fresh parse at every step.
@Test func longFirstLineMatchesParsingFromScratch() {
    var generator = SeededGenerator(state: 77)
    var mismatches: [String] = []
    for _ in 0..<20 {
        let line = randomInline(length: 160, using: &generator).replacingOccurrences(of: "\n", with: " ")
        for prefix in ["", "# ", "> ", "- ", "1. ", "| a | b"] {
            var parser = MarkdownStreamParser(idPrefix: "l")
            var sent = ""
            for character in prefix + line {
                parser.append(String(character))
                sent.append(character)
                var fresh = MarkdownStreamParser(idPrefix: "l")
                fresh.append(sent)
                if parser.document != fresh.document, mismatches.count < 5 {
                    mismatches.append("\(sent.debugDescription): \(parser.document.blocks.last?.text.debugDescription ?? "-") vs \(fresh.document.blocks.last?.text.debugDescription ?? "-")")
                }
            }
        }
    }
    #expect(mismatches.isEmpty, "\(mismatches.joined(separator: "\n"))")
}

/// The inline parse of a paragraph of many single-newline lines resumes
/// near its end with the option too, so an update does not parse it whole.
@Test func checkpointKeepsUpWithLineBreaks() {
    let lines = (0..<120).map { "Line \($0) with **bold**, `code` and a < b." }
    for newlines in [false, true] {
        var state = BlockParser.State(newlinesAsLineBreaks: newlines)
        for line in lines { state.process(line) }
        let source = state.blocks[0].inlineSource().units
        #expect(source.contains(UInt16(UInt8(ascii: "\n"))) == newlines)
        var checkpoint = InlineParser.Checkpoint()
        var end = 0
        while end < source.count {
            end = min(end + 7, source.count)
            _ = InlineParser.parse(Array(source[..<end]), open: true, stableLength: end, resumingFrom: &checkpoint)
        }
        #expect(source.count - checkpoint.position < 10, "newlines: \(newlines)")
    }
}

/// The UTF-8 decoder used for lines gives the same units as `utf16`.
@Test func utf16DecoderMatchesTheStandardLibrary() {
    for text in ["", "plain", "café", "日本語", "👩‍💻 and 🇺🇸", "e\u{301}", "\u{10FFFF}\u{FFFD}", String(repeating: "aé日😀", count: 50)] {
        #expect(BlockParser.utf16(text) == Array(text.utf16))
        #expect(BlockParser.utf16(text.dropFirst()) == Array(text.dropFirst().utf16))
    }
}

/// The debug cross-check of the inline parser's settled result runs under the
/// test suite, so every parse in these tests checks it.
@Test func settledResultIsCheckedInTests() {
    #expect(InlineParser.checksSettledResult)
}
