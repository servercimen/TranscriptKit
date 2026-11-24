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

// MARK: Scrolled geometry and drawing

/// The no-wrap code layout, the index of its code block, and the offset of the long line's last character.
private func scrolledCode() -> (layout: DocumentLayout, block: BlockLayout, end: Int) {
    let layout = DocumentLayout(document: codeDocument(), width: 300, style: noWrap())
    let entry = layout.entry(at: 1)
    let end = entry.start + entry.layout.lines[1].range.upperBound - 1
    return (layout, entry.layout, end)
}

@Test func anOffsetIsCutToWhatTheBlockCanScroll() {
    let (layout, block, _) = scrolledCode()
    var scroll = SideScroll()
    scroll["c"] = 10_000
    #expect(scroll.offset(of: block) == block.maximumScrollOffset)
    scroll["c"] = -5
    #expect(scroll.isEmpty)
    scroll["p"] = 40
    #expect(scroll.offset(of: layout.entry(at: 0).layout) == 0)
}

@Test func onlyTheBoxOfABlockThatScrollsTakesASidewaysPan() {
    let (layout, _, _) = scrolledCode()
    let code = layout.entry(at: 1)
    #expect(layout.sideScrollingEntryIndex(at: CGPoint(x: 150, y: code.frame.midY)) == 1)
    #expect(layout.sideScrollingEntryIndex(at: CGPoint(x: 150, y: layout.entry(at: 0).frame.midY)) == nil)
    #expect(layout.sideScrollingEntryIndex(at: CGPoint(x: 150, y: code.frame.maxY + 2)) == nil)
    let wrapped = DocumentLayout(document: codeDocument(), width: 300)
    #expect(wrapped.sideScrollingEntryIndex(at: CGPoint(x: 150, y: wrapped.entry(at: 1).frame.midY)) == nil)
    #expect(layout.entryIndex(ofBlock: "c") == 1)
    #expect(layout.entryIndex(ofBlock: "c", hint: 1) == 1)
    #expect(layout.entryIndex(ofBlock: "x") == nil)
}

@Test func caretsMoveWithTheOffsetAndStayInTheBox() {
    let (layout, block, end) = scrolledCode()
    let code = layout.entry(at: 1)
    // Unscrolled, the end of the long line is past the box: its caret waits at the edge.
    let unscrolled = layout.caretRect(at: end, scroll: .none)
    #expect(unscrolled.maxX == 300)
    var scroll = SideScroll()
    scroll["c"] = block.maximumScrollOffset
    let scrolled = layout.caretRect(at: end, scroll: scroll)
    #expect(abs(scrolled.minX - (block.caretRect(atOffset: end - code.start).minX - block.maximumScrollOffset)) < 0.01)
    #expect(scrolled.maxX < 300)
    // The first character has moved out of the box, to the left.
    let start = layout.entry(at: 1).start + block.lines[1].range.lowerBound
    #expect(layout.caretRect(at: start, scroll: scroll).minX == 0)
    // A block that does not scroll is not moved.
    #expect(layout.caretRect(at: 3, scroll: scroll) == layout.caretRect(at: 3))
}

@Test func hitTestingFollowsTheOffset() {
    let (layout, block, end) = scrolledCode()
    var scroll = SideScroll()
    scroll["c"] = block.maximumScrollOffset
    let caret = layout.caretRect(at: end, scroll: scroll)
    #expect(layout.closestOffset(to: CGPoint(x: caret.midX, y: caret.midY), scroll: scroll) == end)
    #expect(layout.closestOffset(to: CGPoint(x: caret.midX, y: caret.midY)) != end)
}

@Test func selectionRectsAreCutToTheBox() {
    let (layout, block, _) = scrolledCode()
    let code = layout.entry(at: 1)
    let range = code.start..<(code.start + block.length)
    let wide = block.selectionRects(for: 0..<block.length)
    #expect(wide.contains { $0.maxX > 300 })
    let cut = layout.selectionRects(for: range, scroll: .none)
    #expect(cut.count == wide.count)
    #expect(cut.allSatisfy { $0.minX >= 0 && $0.maxX <= 300 })
    var scroll = SideScroll()
    scroll["c"] = block.maximumScrollOffset
    // The first line is short: scrolled out of the box, its rect is empty at the leading edge.
    let scrolled = layout.selectionRects(for: range, scroll: scroll)
    #expect(scrolled[0].minX == 0 && scrolled[0].width == 0)
    #expect(scrolled[1].minX == 0 && scrolled[1].width > 250)
}

@Test func aLinkInABlockThatScrollsIsFoundAtItsScrolledPlace() {
    let text = String(repeating: "x", count: 60) + " link"
    let span = InlineSpan(range: 61..<65, link: "https://example.com")
    let document = TranscriptDocument(blocks: [TranscriptBlock(id: "c", kind: .code(), text: text, spans: [span])])
    let layout = DocumentLayout(document: document, width: 300, style: noWrap())
    let block = layout.entry(at: 0).layout
    var scroll = SideScroll()
    scroll["c"] = block.maximumScrollOffset
    let caret = layout.caretRect(at: 63, scroll: scroll)
    let point = CGPoint(x: caret.midX, y: caret.midY)
    #expect(layout.link(at: point, scroll: scroll) == "https://example.com")
    #expect(layout.link(at: point, scroll: .none) == nil)
    // Past the edge of the box, the link is not shown, so it is not there.
    let hidden = block.caretRect(atOffset: 63)
    #expect(hidden.minX > 300)
    #expect(layout.link(at: CGPoint(x: hidden.midX, y: hidden.midY), scroll: .none) == nil)
}

private func drawn(_ layout: DocumentLayout, scroll: SideScroll, scale: CGFloat = 2) -> (bytes: [UInt8], width: Int) {
    let width = Int(layout.width * scale)
    let height = Int((layout.height * scale).rounded(.up))
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: scale, y: -scale)
    layout.draw(in: context, dirtyRect: CGRect(x: 0, y: 0, width: layout.width, height: layout.height),
                text: CGColor(gray: 0, alpha: 1), codeBackground: CGColor(gray: 0.9, alpha: 1), accent: CGColor(gray: 0.6, alpha: 1),
                dark: false, hiding: .none, scroll: scroll)
    return (Array(UnsafeRawBufferPointer(start: context.data!, count: width * height * 4)), width)
}

@Test func theDrawingFollowsTheOffsetInsideTheBox() {
    let (layout, _, _) = scrolledCode()
    let code = layout.entry(at: 1)
    var scroll = SideScroll()
    scroll["c"] = 40
    let still = drawn(layout, scroll: .none)
    let moved = drawn(layout, scroll: scroll)
    let scale = 2
    let shift = 40 * scale
    // Inside the box, each pixel is the one 40 points to its right before.
    var mismatches = 0
    var ink = 0
    let rows = Int((code.y + code.layout.lines[1].frame.minY) * 2)..<Int((code.y + code.layout.lines[1].frame.maxY) * 2)
    for row in rows {
        for column in 0..<(still.width - shift) {
            let a = (row * still.width + column) * 4
            let b = (row * still.width + column + shift) * 4
            if moved.bytes[a] != still.bytes[b] { mismatches += 1 }
            if moved.bytes[a + 3] == 255 && moved.bytes[a] < 100 { ink += 1 }
        }
    }
    #expect(mismatches == 0)
    #expect(ink > 100)
    // The text around the block does not move.
    let paragraph = Int((layout.entry(at: 0).frame.midY) * 2) * still.width * 4
    #expect(moved.bytes[paragraph..<(paragraph + still.width * 4)] == still.bytes[paragraph..<(paragraph + still.width * 4)])
}

@Test func theTailIsDrawnWithTheOffset() {
    // The long line is the last one, so the tail starts at it.
    let document = TranscriptDocument(blocks: [TranscriptBlock(id: "c", kind: .code(), text: "let a = 1\n" + longLine)])
    let layout = DocumentLayout(document: document, width: 300, style: noWrap())
    var scroll = SideScroll()
    scroll["c"] = 40
    let colors = TailRenderer.Colors(text: CGColor(gray: 0, alpha: 1), codeBackground: CGColor(gray: 0.9, alpha: 1),
                                     accent: CGColor(gray: 0.6, alpha: 1))
    let plain = TailRenderer(colors: colors, scale: 2)
    let moved = TailRenderer(colors: colors, scale: 2)
    _ = plain.render(layout, changedTop: nil)
    _ = moved.render(layout, changedTop: nil, scroll: scroll)
    #expect(plain.currentPixels() != moved.currentPixels())
    let again = TailRenderer(colors: colors, scale: 2)
    _ = again.render(layout, changedTop: nil, scroll: scroll)
    #expect(again.currentPixels() == moved.currentPixels())
}

@Test func fadingTextInABlockThatScrollsIsCutToTheBox() {
    let (layout, block, _) = scrolledCode()
    let code = layout.entry(at: 1)
    let colors = TailRenderer.Colors(text: CGColor(gray: 0, alpha: 1), codeBackground: CGColor(gray: 0.9, alpha: 1),
                                     accent: CGColor(gray: 0.6, alpha: 1))
    let fade = Fade(id: 1, range: code.start..<layout.length, start: 0)
    func inCode(_ frame: FadeFrame?) -> [FadeFrame.Piece] {
        (frame?.pieces ?? []).filter { $0.frame.midY < code.frame.maxY }
    }
    let plain = inCode(FadeRenderer().render(layout, from: code.start, fades: [fade], colors: colors, scale: 2, playing: []))
    #expect(plain.count == 4)
    #expect(plain.allSatisfy { $0.frame.minX >= 0 && $0.frame.maxX <= 300 })
    var scroll = SideScroll()
    scroll["c"] = block.maximumScrollOffset
    let pieces = inCode(FadeRenderer().render(layout, from: code.start, fades: [fade], colors: colors, scale: 2, playing: [],
                                              scroll: scroll))
    #expect(pieces.allSatisfy { $0.frame.minX >= 0 && $0.frame.maxX <= 300 })
    // The long line starts out of the box, to the left, and its end is in the box now.
    #expect(pieces.contains { $0.frame.minX == 0 && $0.frame.maxX > 280 })
}

// MARK: Pans

@Test func aPanScrollsABlockOnlySidewaysAndOnlyWhereItCanMove() {
    let (layout, block, end) = scrolledCode()
    let point = CGPoint(x: 150, y: layout.entry(at: 1).frame.midY)
    let left = CGPoint(x: -300, y: 40)
    // At the start, a pan to the left moves the lines; a pan to the right, or up and down, does not.
    #expect(layout.sidePanEntryIndex(at: point, velocity: left, scroll: .none) == 1)
    #expect(layout.sidePanEntryIndex(at: point, velocity: CGPoint(x: 300, y: 0), scroll: .none) == nil)
    #expect(layout.sidePanEntryIndex(at: point, velocity: CGPoint(x: -100, y: 300), scroll: .none) == nil)
    var scroll = SideScroll()
    scroll["c"] = block.maximumScrollOffset
    #expect(layout.sidePanEntryIndex(at: point, velocity: left, scroll: scroll) == nil)
    #expect(layout.sidePanEntryIndex(at: point, velocity: CGPoint(x: 300, y: 0), scroll: scroll) == 1)
    // Outside a block that scrolls.
    #expect(layout.sidePanEntryIndex(at: CGPoint(x: 150, y: layout.entry(at: 0).frame.midY), velocity: left, scroll: .none) == nil)
    // On a selection handle.
    let handle = layout.caretRect(at: end, scroll: .none)
    let onHandle = CGPoint(x: handle.midX - 5, y: handle.midY)
    #expect(layout.sidePanEntryIndex(at: onHandle, velocity: left, scroll: .none) == 1)
    #expect(layout.sidePanEntryIndex(at: onHandle, velocity: left, scroll: .none, handles: [3, end]) == nil)
}

@Test func aBlockSlowsDownAsInAScrollView() {
    let first = SideScroll.decelerate(velocity: 1000, for: 1.0 / 60)
    #expect(first.velocity < 1000 && first.velocity > 960)
    #expect(first.distance > 16 && first.distance < 17)
    // In steps or in one go, it goes as far.
    var velocity: CGFloat = 1000
    var distance: CGFloat = 0
    for _ in 0..<60 {
        let step = SideScroll.decelerate(velocity: velocity, for: 1.0 / 60)
        distance += step.distance
        velocity = step.velocity
    }
    let whole = SideScroll.decelerate(velocity: 1000, for: 1)
    #expect(abs(distance - whole.distance) < 0.01)
    #expect(abs(velocity - whole.velocity) < 0.01)
    // It stops after about 500 points: the speed divided by the rate's logarithm.
    #expect(abs(SideScroll.decelerate(velocity: 1000, for: 10).distance - 1000 / (-1000 * log(0.998))) < 1)
    #expect(SideScroll.decelerate(velocity: -1000, for: 0.1).distance < 0)
}
