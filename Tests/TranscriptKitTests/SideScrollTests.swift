import CoreGraphics
import Foundation
import Testing
@testable import TranscriptKit

private let longLine = "let values = [" + (1...40).map(String.init).joined(separator: ", ") + "]"
private let code = "func f() {\n    " + longLine + "\n    return values\n}"

private func codeDocument(_ text: String = code) -> TranscriptDocument {
    TranscriptDocument(blocks: [
        TranscriptBlock(id: "p", text: "Some text before the code."),
        TranscriptBlock(id: "c", kind: .code(language: "swift"), text: text),
        TranscriptBlock(id: "q", text: "Some text after the code."),
    ])
}

private func noWrap() -> TranscriptStyle {
    var style = TranscriptStyle()
    style.codeWraps = false
    return style
}

@Test func codeWrapsByDefaultAndDoesNotScroll() {
    let layout = DocumentLayout(document: codeDocument(), width: 300)
    let block = layout.entry(at: 1).layout
    #expect(block.lines.count > 4)
    #expect(block.maximumScrollOffset == 0)
    #expect(block.lines.allSatisfy { $0.frame.maxX <= 300 })
}

@Test func codeThatDoesNotWrapHasOneLineForEachLineOfText() {
    let style = noWrap()
    let layout = DocumentLayout(document: codeDocument(), width: 300, style: style)
    let block = layout.entry(at: 1).layout
    #expect(block.lines.count == 4)
    let widest = block.lines.map(\.frame.maxX).max()!
    #expect(widest > 300)
    #expect(block.contentRight == widest)
    #expect(block.maximumScrollOffset == ceil(widest + style.codePadding - 300))
    // The block keeps the width of the column; the text around it still wraps.
    #expect(layout.entry(at: 1).frame.width == 300)
    #expect(layout.entry(at: 0).layout.maximumScrollOffset == 0)
}

@Test func codeThatFitsDoesNotScroll() {
    let layout = DocumentLayout(document: codeDocument("let a = 1\nlet b = 2"), width: 300, style: noWrap())
    #expect(layout.entry(at: 1).layout.lines.count == 2)
    #expect(layout.entry(at: 1).layout.maximumScrollOffset == 0)
}

@Test func aStreamedCodeBlockThatDoesNotWrapMatchesALayoutFromScratch() {
    let style = noWrap()
    var previous: DocumentLayout?
    let units = Array(code.utf16)
    for end in stride(from: 1, through: units.count, by: 3) {
        let text = String(utf16CodeUnits: units, count: end)
        let document = TranscriptDocument(blocks: [TranscriptBlock(id: "c", kind: .code(language: "swift"), text: text)])
        let streamed = DocumentLayout(document: document, width: 300, style: style, reusing: previous)
        let fresh = DocumentLayout(document: document, width: 300, style: style)
        let a = streamed.entry(at: 0).layout
        let b = fresh.entry(at: 0).layout
        #expect(a.lines.map(\.range) == b.lines.map(\.range), "at \(end)")
        // Typeset from a different start, a line's width can differ in the last bits.
        let same = zip(a.lines, b.lines).allSatisfy { abs($0.frame.minX - $1.frame.minX) < 0.01 && $0.frame.minY == $1.frame.minY
            && abs($0.frame.width - $1.frame.width) < 0.01 }
        #expect(same, "at \(end)")
        #expect(abs(a.maximumScrollOffset - b.maximumScrollOffset) <= 1, "at \(end)")
        previous = streamed
    }
}

@Test func aLineLimitKeepsTheScrollWidthOfTheLinesShown() {
    var style = noWrap()
    style.lineLimit = 3
    let document = TranscriptDocument(blocks: [TranscriptBlock(id: "c", kind: .code(), text: code)])
    let block = DocumentLayout(document: document, width: 300, style: style).entry(at: 0).layout
    #expect(block.lines.count == 3)
    #expect(block.maximumScrollOffset > 0)
    // The last line shown ends in "…" at the edge of the column.
    style.lineLimit = 2
    let cut = DocumentLayout(document: document, width: 300, style: style).entry(at: 0).layout
    #expect(cut.lines.count == 2)
    #expect(cut.maximumScrollOffset == 0)
}

// MARK: Display math

/// An opaque formula image, `width` by `height` points.
private func formula(width: Int, height: Int) -> TranscriptMathImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return TranscriptMathImage(image: context.makeImage()!, size: CGSize(width: width, height: height), baseline: 4)
}

/// The first block of `markdown` laid out at `width` once its formula, `formulaWidth` points wide, is drawn.
private func mathBlock(_ markdown: String, formulaWidth: Int, width: CGFloat = 300, style: TranscriptStyle) async -> BlockLayout {
    let store = TranscriptImageStore()
    store.setMathRenderer { _, _ in formula(width: formulaWidth, height: 20) }
    let document = MarkdownStreamParser.document(from: markdown)
    let revision = store.revision
    _ = DocumentLayout(document: document, width: width, style: style, reusing: nil, images: store)
    for _ in 0..<200 where store.revision == revision {
        try? await Task.sleep(for: .milliseconds(10))
    }
    return DocumentLayout(document: document, width: width, style: style, reusing: nil, images: store).entry(at: 0).layout
}

@Test func displayMathCanAlignToTheLeadingEdge() async {
    var style = TranscriptStyle()
    #expect(abs((await mathBlock("$$x$$", formulaWidth: 60, style: style)).lines[0].frame.midX - 150) <= 1)
    style.displayMathAlignment = .leading
    #expect((await mathBlock("$$x$$", formulaWidth: 60, style: style)).lines[0].frame.minX == 0)
    style.displayMathAlignment = .trailing
    #expect((await mathBlock("$$x$$", formulaWidth: 60, style: style)).lines[0].frame.maxX == 300)
    // Inline math follows the text, not the display math alignment.
    let inline = await mathBlock("Area \\(x\\) here", formulaWidth: 60, style: style)
    #expect(inline.lines[0].frame.minX == 0)
}

@Test func aWideFormulaIsScaledDownUnlessItScrolls() async {
    var style = TranscriptStyle()
    let scaled = await mathBlock("$$x$$", formulaWidth: 500, style: style)
    #expect(scaled.lines[0].frame.width <= 300)
    #expect(scaled.maximumScrollOffset == 0)

    style.displayMathScrolls = true
    let scrolled = await mathBlock("$$x$$", formulaWidth: 500, style: style)
    #expect(scrolled.lines.count == 1)
    #expect(scrolled.lines[0].frame.minX == 0)
    #expect(scrolled.lines[0].frame.width == 500)
    #expect(scrolled.maximumScrollOffset == 200)
    // A formula that fits is aligned as before, and does not scroll.
    let narrow = await mathBlock("$$x$$", formulaWidth: 60, style: style)
    #expect(abs(narrow.lines[0].frame.midX - 150) <= 1)
    #expect(narrow.maximumScrollOffset == 0)
    // Inline formulas are still scaled down.
    let inline = await mathBlock("Area \\(x\\) here", formulaWidth: 500, style: style)
    #expect(inline.maximumScrollOffset == 0)
    #expect(inline.lines.allSatisfy { $0.frame.maxX <= 300 })
}

@Test func aFormulaThatScrollsShowsAllOfItsLatexUntilItIsDrawn() {
    var style = TranscriptStyle()
    let tex = "$$" + String(repeating: "a + b + c + ", count: 12) + "d$$"
    let document = MarkdownStreamParser.document(from: tex)
    let truncated = DocumentLayout(document: document, width: 300, style: style).entry(at: 0).layout
    #expect(truncated.maximumScrollOffset == 0)
    style.displayMathScrolls = true
    let whole = DocumentLayout(document: document, width: 300, style: style).entry(at: 0).layout
    #expect(whole.maximumScrollOffset > 0)
    #expect(whole.lines[0].frame.minX == 0)
}
