import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import TranscriptKit

private func firstBlock(_ markdown: String) -> TranscriptBlock {
    MarkdownStreamParser.document(from: markdown).blocks[0]
}

private func formulas(_ block: TranscriptBlock) -> [TranscriptMath] {
    block.spans.compactMap(\.math)
}

@Test func inlineAndDisplayMathAreParsed() {
    let inline = firstBlock("Euler: \\(e^{i\\pi} + 1 = 0\\) holds.")
    #expect(formulas(inline) == [TranscriptMath(tex: "e^{i\\pi} + 1 = 0", isDisplay: false)])
    #expect(inline.text == "Euler: \u{FFFC} holds.")
    #expect(formulas(firstBlock("\\[ x^2 \\]")) == [TranscriptMath(tex: "x^2", isDisplay: true)])
    #expect(firstBlock("\\[ x^2 \\]").text == "\u{FFFC}")
    #expect(formulas(firstBlock("$$a + b$$")) == [TranscriptMath(tex: "a + b", isDisplay: true)])
    // Display math on lines of its own, in one paragraph.
    #expect(formulas(firstBlock("$$\nx = 1\n$$")) == [TranscriptMath(tex: "x = 1", isDisplay: true)])
}

@Test func latexIsKeptWholeAndNotReadAsMarkdown() {
    let block = firstBlock("\\(a_1 * b_2 * c_3\\) and \\(\\begin{pmatrix} a \\\\) b \\end{pmatrix}\\)")
    #expect(formulas(block).map(\.tex) == ["a_1 * b_2 * c_3", "\\begin{pmatrix} a \\\\) b \\end{pmatrix}"])
    #expect(!block.spans.contains { $0.traits.contains(.italic) })
}

@Test func dollarsInTextAreNotMath() {
    let prices = firstBlock("It costs $5 now and $10 later.")
    #expect(formulas(prices).isEmpty)
    #expect(prices.text == "It costs $5 now and $10 later.")
    let unclosed = firstBlock("Only $$ here.")
    #expect(formulas(unclosed).isEmpty)
    #expect(unclosed.text == "Only $$ here.")
}

@Test func anUnclosedOpenerInFinishedTextIsAnEscape() {
    let block = firstBlock("Not math: \\(x")
    #expect(formulas(block).isEmpty)
    #expect(block.text == "Not math: (x")
}

@Test func streamedMathMatchesParsingAtOnceAndShowsNothingUntilItCloses() {
    let source = "Before \\(x^2 + y^2\\) after, and $$\\sum_i i$$ too."
    var parser = MarkdownStreamParser(idPrefix: "md")
    var shownSource: [String] = []
    for character in source {
        parser.append(String(character))
        let text = parser.document.blocks.last?.text ?? ""
        if text.contains("\\") || text.contains("$") { shownSource.append(text) }
    }
    parser.finish()
    #expect(shownSource.isEmpty)
    #expect(parser.document == MarkdownStreamParser.document(from: source))
    #expect(formulas(parser.document.blocks[0]).count == 2)
}

@Test func aStrayOpenerShowsAsTextOnceItIsFarBehind() {
    let tail = String(repeating: "word ", count: 120)
    var parser = MarkdownStreamParser(idPrefix: "md")
    parser.append("Before \\( " + tail)
    #expect(parser.document.blocks[0].text == "Before ( " + tail.dropLast())
    var dollars = MarkdownStreamParser(idPrefix: "md")
    dollars.append("Only $$ " + tail)
    #expect(dollars.document.blocks[0].text == "Only $$ " + tail.dropLast())
}

@Test func anEmptyFormulaShowsAsWritten() {
    #expect(firstBlock("a $$ $$ b").text == "a $$ $$ b")
    #expect(firstBlock("a \\(\\) b").text == "a \\(\\) b")
}

private let mathSamples = [
    "Euler \\(e^{i\\pi} + 1 = 0\\) costs $5, not $$\\sum_{k=1}^{n} k$$, and \\[\\frac{a}{b} \\\\ c\\] **bold \\(x_1\\) here**.",
    "Not math: \\(x and $$y, then *it* " + String(repeating: "word ", count: 120),
    "$$ $$ and \\(\\) and \\\\(x\\) and $ $ and \\[a \\$ b\\]",
]

/// The resumable path, with every unit before the end promised stable, as
/// for a long line that keeps growing.
@Test func checkpointedMathParsesOnlyGrowAndMatchAParseFromScratch() {
    for source in mathSamples {
        let units = Array(source.utf16)
        var checkpoint = InlineParser.Checkpoint()
        var previous = ""
        var shrank: [String] = []
        for end in 1...units.count {
            let result = InlineParser.parse(Array(units[..<end]), open: true, stableLength: end, resumingFrom: &checkpoint, tags: [:])
            if !result.text.hasPrefix(previous), shrank.count < 3 { shrank.append(previous + " -> " + result.text) }
            previous = result.text
        }
        #expect(shrank.isEmpty, "\(shrank)")
        let resumed = InlineParser.parse(units, open: false, stableLength: units.count, resumingFrom: &checkpoint, tags: [:])
        #expect(resumed == InlineParser.parse(source, open: false, tags: [:]), "\(source)")
    }
}

@Test func everySplitPointGivesTheSameMath() {
    for source in mathSamples + displaySamples {
        let whole = MarkdownStreamParser.document(from: source, idPrefix: "m")
        var mismatches: [Int] = []
        for split in 1..<source.count {
            var parser = MarkdownStreamParser(idPrefix: "m")
            parser.append(String(source.prefix(split)))
            parser.append(String(source.dropFirst(split)))
            parser.finish()
            if parser.document != whole { mismatches.append(split) }
        }
        #expect(mismatches.isEmpty, "differs when split at \(mismatches.prefix(10))")
    }
}

@Test func copyingMathGivesItsLatex() {
    let inline = MarkdownStreamParser.document(from: "Area \\(\\pi r^2\\) here")
    #expect(inline.copyText(in: 0..<inline.utf16Count) == "Area \\(\\pi r^2\\) here")
    let display = MarkdownStreamParser.document(from: "$$\nE = mc^2\n$$")
    #expect(display.copyText(in: 0..<display.utf16Count) == "\\[E = mc^2\\]")
}

@Test func escapedBracketsInALineStayText() {
    let block = firstBlock("See \\[1\\] and \\[2\\].")
    #expect(formulas(block).isEmpty)
    #expect(block.text == "See [1] and [2].")
    #expect(firstBlock("\\[1\\] Smith et al.").text == "[1] Smith et al.")
}

private func blocks(_ markdown: String) -> [(text: String, tex: [String])] {
    MarkdownStreamParser.document(from: markdown).blocks.map { ($0.text, formulas($0).map(\.tex)) }
}

@Test func displayMathIsABlockThatKeepsItsLines() {
    let list = blocks("\\[\nx = a\n- b\n# c\n\\]")
    #expect(list.count == 1)
    #expect(list.first?.tex == ["x = a\n- b\n# c"])
    let split = blocks("Text\n$$\nx^2\n$$\nmore text")
    #expect(split.map(\.text) == ["Text", "\u{FFFC}", "more text"])
    #expect(split[1].tex == ["x^2"])
    // In a list item and in a quote.
    #expect(blocks("1. Item\n2. \\[\n   y = 2\n   \\]").last?.tex == ["y = 2"])
    #expect(blocks("> \\[\n> a \\\\\n> b\n> \\]").first?.tex == ["a \\\\\nb"])
}

@Test func textAfterTheCloserStartsAParagraph() {
    let result = blocks("\\[\nx = 1\n\\] Then more.")
    #expect(result.map(\.text) == ["\u{FFFC}", "Then more."])
    // On its opening line, text after the closer makes it part of the paragraph.
    let inline = firstBlock("$$x$$ and more")
    #expect(inline.text == "\u{FFFC} and more")
    #expect(formulas(inline) == [TranscriptMath(tex: "x", isDisplay: true)])
}

@Test func withABlankLineBeforeTheCloserItIsNotAFormula() {
    let result = blocks("$$\nx = a\n- b\n\nAfter.")
    #expect(result.map(\.text) == ["$$ x = a - b", "After."])
    #expect(result.allSatisfy { $0.tex.isEmpty })
    // Never closed: its lines show as written.
    #expect(blocks("\\[\nx = a\n- b").map(\.text) == ["[ x = a - b"])
}

private let displaySamples = [
    "Roots:\n\\[\nx = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}\n\\]\nand then\n\n$$\n\\begin{aligned}\na &= b \\\\\n- c &= d\n\\end{aligned}\n$$\n\n- item \\(x\\)\n  \\[\n  y\n  \\] after\n",
    "$$\nnever closed\n# not a heading\n\nNext paragraph with $5.\n\\[1\\] Smith.\n$$x$$\n",
]

@Test func streamedDisplayMathOnlyGrowsAndMatchesParsingAtOnce() {
    for source in displaySamples {
        var parser = MarkdownStreamParser(idPrefix: "md")
        var previous = parser.document
        var shrank: [String] = []
        for character in source {
            parser.append(String(character))
            if !parser.document.extends(previous), shrank.count < 3 {
                shrank.append("\(previous.blocks.last?.text.debugDescription ?? "-") -> \(parser.document.blocks.last?.text.debugDescription ?? "-")")
            }
            previous = parser.document
        }
        parser.finish()
        #expect(shrank.isEmpty, "\(shrank)")
        #expect(parser.document == MarkdownStreamParser.document(from: source))
    }
}

/// A formula image as a renderer makes one: RGBA, transparent, with an
/// opaque black box in its middle third. `width` by `height` points, its
/// baseline `baseline` above the bottom.
private func boxFormula(width: Int, height: Int, baseline: CGFloat) -> TranscriptMathImage {
    let scale = 2
    let context = CGContext(data: nil, width: width * scale, height: height * scale, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(CGRect(x: width * scale / 3, y: 0, width: width * scale / 3, height: height * scale))
    return TranscriptMathImage(image: context.makeImage()!, size: CGSize(width: width, height: height), baseline: baseline)
}

private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<200 where !condition() {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

private func attachment(in layout: DocumentLayout) -> ImageAttachment? {
    let line = layout.entry(at: 0).layout.lines[0]
    for run in CTLineGetGlyphRuns(line.ctLine) as! [CTRun] {
        let attributes = CTRunGetAttributes(run) as NSDictionary
        if let attachment = attributes[TranscriptStyle.imageKey.rawValue] as? ImageAttachment { return attachment }
    }
    return nil
}

@Test func aFormulaShowsItsLatexUntilTheRendererDrawsIt() async {
    let store = TranscriptImageStore()
    store.setMathRenderer { _, fontSize in
        boxFormula(width: 40, height: Int(fontSize), baseline: 5)
    }
    let document = MarkdownStreamParser.document(from: "So \\(x\\) here")
    let revision = store.revision
    let first = DocumentLayout(document: document, width: 300, style: TranscriptStyle(), reusing: nil, images: store)
    #expect(attachment(in: first)?.picture == nil)
    #expect(attachment(in: first)?.label != nil)
    await waitUntil { store.revision > revision }
    let second = DocumentLayout(document: document, width: 300, style: TranscriptStyle(), reusing: first, images: store)
    let drawn = attachment(in: second)
    #expect(drawn?.isMask == true)
    #expect(drawn?.size == CGSize(width: 40, height: 17))
    #expect(drawn?.ascent == 12)
}

@Test func displayMathIsCentredAndDrawnInTheTextColor() async {
    let store = TranscriptImageStore()
    store.setMathRenderer { _, _ in boxFormula(width: 60, height: 20, baseline: 4) }
    let document = MarkdownStreamParser.document(from: "$$x$$")
    let revision = store.revision
    _ = DocumentLayout(document: document, width: 300, style: TranscriptStyle(), reusing: nil, images: store)
    await waitUntil { store.revision > revision }
    let layout = DocumentLayout(document: document, width: 300, style: TranscriptStyle(), reusing: nil, images: store)
    let line = layout.entry(at: 0).layout.lines[0]
    #expect(abs(line.frame.midX - 150) <= 1)

    let scale: CGFloat = 2
    let width = Int(layout.width * scale)
    let height = Int((layout.height * scale).rounded())
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: scale, y: -scale)
    layout.draw(in: context, dirtyRect: CGRect(x: 0, y: 0, width: layout.width, height: layout.height),
                text: CGColor(red: 1, green: 0, blue: 0, alpha: 1), codeBackground: CGColor(gray: 0.9, alpha: 1),
                accent: CGColor(gray: 0.6, alpha: 1), dark: false)
    let bytes = UnsafeRawBufferPointer(start: context.data!, count: width * height * 4)
    func pixel(_ x: CGFloat) -> (UInt8, UInt8, UInt8) {
        let index = (Int(((line.baseline - 6) * scale).rounded()) * width + Int((x * scale).rounded())) * 4
        return (bytes[index], bytes[index + 1], bytes[index + 2])
    }
    // The box is drawn in the text color, and the transparent sides are not drawn.
    let middle = pixel(line.frame.midX)
    #expect(middle.0 > 200 && middle.1 < 60 && middle.2 < 60)
    let side = pixel(line.frame.midX - 25)
    #expect(side.0 > 200 && side.1 > 200 && side.2 > 200)
}
