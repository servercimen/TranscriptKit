import CoreGraphics
import CoreText
import Foundation
import IOSurface
import Testing
@testable import TranscriptKit

private let colors = TailRenderer.Colors(
    text: CGColor(gray: 0, alpha: 1),
    codeBackground: CGColor(gray: 0.9, alpha: 1),
    accent: CGColor(gray: 0.6, alpha: 1)
)

private let sample = """
# Fading in

Some text with **bold**, *italic*, ~~struck through~~ words, `inline code`, and a [link](https://example.com) that wraps \
when its line is full of supercalifragilisticexpialidocious words and more.

- A list item that is long enough to wrap onto a second line of the list
- Another ~~item~~ with a [link](https://example.org)

```swift
let fading = true
```

| A first cell long enough to wrap onto more lines in its column | B |
| --- | --- |
| one | two |

A last paragraph, centered or not, that ends the sample.
"""

private final class Clock: @unchecked Sendable {
    var now: CFTimeInterval = 1000
}

/// Streams `markdown` through a layout engine whose fades last `duration`,
/// moving its clock one frame on per update, and calls `check` with every
/// output.
private func streamFades(_ markdown: String, chunk: Int, style: TranscriptStyle = .init(), duration: CFTimeInterval = 0.1,
                         check: (LayoutEngine.Output) -> Void) {
    let engine = LayoutEngine()
    let clock = Clock()
    engine.clock = { clock.now }
    engine.setTailStyle(colors: colors, scale: 2)
    engine.setFadeDuration(duration)
    _ = engine.relayout(width: 320, style: style)
    var parser = MarkdownStreamParser(idPrefix: "f")
    var rest = Substring(markdown)
    var sequence = 0
    while !rest.isEmpty {
        parser.append(String(rest.prefix(chunk)))
        rest = rest.dropFirst(chunk)
        sequence += 1
        engine.submit(.init(document: parser.document, source: 1, sequence: sequence))
        engine.drainNow()
        if let output = engine.takeOutput() { check(output) }
        clock.now += 1.0 / 60
    }
}

private func bitmap(width: Int, height: Int) -> CGContext {
    CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
              space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
}

/// Draws the pieces, at full opacity, into a top-left-origin context in
/// document points whose top left is at `origin`.
private func composite(_ fade: FadeFrame?, into context: CGContext, origin: CGPoint, scale: CGFloat) {
    guard let fade else { return }
    let height = CGFloat(context.height)
    for piece in fade.pieces {
        // Core Graphics draws images y-up.
        let x = (piece.frame.minX - origin.x) * scale
        let y = height - (piece.frame.maxY - origin.y) * scale
        context.draw(piece.image, in: CGRect(x: x, y: y, width: piece.frame.width * scale, height: piece.frame.height * scale))
    }
}

private func bytes(of context: CGContext) -> [UInt8] {
    Array(UnsafeRawBufferPointer(start: context.data!, count: context.bytesPerRow * context.height))
}

/// Bytes that differ by more than 2, and the largest difference.
private func differing(_ a: [UInt8], _ b: [UInt8]) -> (count: Int, largest: Int) {
    guard a.count == b.count else { return (max(a.count, b.count), 255) }
    let identical = a.withUnsafeBytes { x in b.withUnsafeBytes { y in memcmp(x.baseAddress!, y.baseAddress!, x.count) == 0 } }
    if identical { return (0, 0) }
    var count = 0
    var largest = 0
    for (x, y) in zip(a, b) {
        let difference = abs(Int(x) - Int(y))
        if difference > 2 { count += 1 }
        largest = max(largest, difference)
    }
    return (count, largest)
}

/// The document from the fading text down: drawn with that text left out,
/// plus the pieces, against drawn in one go. Above it, nothing is left out.
private func documentDifference(_ output: LayoutEngine.Output, scale: CGFloat) -> (count: Int, largest: Int) {
    let layout = output.layout
    guard let from = output.hidden.fadingFrom else { return (output.fade == nil ? 0 : 1, 0) }
    let margin = TailRenderer.sideMargin
    let top = max(((layout.caretRect(at: from).minY - 40) * scale).rounded(.down) / scale, 0)
    let band = CGRect(x: -margin, y: top, width: layout.width + 2 * margin, height: layout.height + 32 - top)
    let width = Int((band.width * scale).rounded())
    let height = Int((band.height * scale).rounded())
    func drawn(hiding: TagHiding) -> CGContext {
        let context = bitmap(width: width, height: height)
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: margin, y: -top)
        context.clip(to: band)
        layout.draw(in: context, dirtyRect: band, text: colors.text, codeBackground: colors.codeBackground, accent: colors.accent,
                    dark: false, hiding: hiding)
        context.restoreGState()
        return context
    }
    let actual = drawn(hiding: output.hidden)
    composite(output.fade, into: actual, origin: CGPoint(x: -margin, y: top), scale: scale)
    return differing(bytes(of: actual), bytes(of: drawn(hiding: .none)))
}

/// The tail surface plus the pieces, against the tail drawn in one go.
private func tailDifference(_ output: LayoutEngine.Output, scale: CGFloat) -> (count: Int, largest: Int)? {
    guard let tail = output.tail else { return nil }
    let layout = output.layout
    let margin = TailRenderer.sideMargin
    let width = Int(((layout.width + 2 * margin) * scale).rounded())
    let height = Int((TailRenderer.height * scale).rounded())
    let actual = bitmap(width: width, height: height)
    tail.surface.lock(options: .readOnly, seed: nil)
    for row in 0..<height {
        memcpy(actual.data! + row * actual.bytesPerRow, tail.surface.baseAddress + row * tail.surface.bytesPerRow, width * 4)
    }
    tail.surface.unlock(options: .readOnly, seed: nil)
    composite(output.fade, into: actual, origin: CGPoint(x: -margin, y: tail.top), scale: scale)

    let expected = bitmap(width: width, height: height)
    expected.translateBy(x: 0, y: CGFloat(height))
    expected.scaleBy(x: scale, y: -scale)
    expected.translateBy(x: margin, y: -tail.top)
    let band = CGRect(x: -margin, y: tail.top, width: layout.width + 2 * margin, height: TailRenderer.height)
    expected.clip(to: band)
    layout.draw(in: expected, dirtyRect: band, text: colors.text, codeBackground: colors.codeBackground, accent: colors.accent)
    return differing(bytes(of: actual), bytes(of: expected))
}

/// At every update, the text left out of the drawing is exactly what the
/// fade pieces draw: with the pieces at full opacity, the document and the
/// tail look as if drawn in one go. Lines are laid out again as text
/// arrives (a word wraps, a centered line moves), and the pieces follow.
@Test(arguments: [(3, false), (11, false), (5, true)])
func fadePiecesAndTheDrawingMakeUpTheText(chunk: Int, centered: Bool) {
    var style = TranscriptStyle()
    if centered { style.textAlignment = .center }
    var checked = 0
    var fading = 0
    var mismatches: [String] = []
    var outsideTail = 0
    var step = 0
    streamFades(sample, chunk: chunk, style: style) { output in
        step += 1
        if output.hidden.fadingFrom != nil { fading += 1 }
        // While the strip can hold it, the fading text is in the tail, which
        // draws it when it stops fading, not the tiles.
        if let from = output.hidden.fadingFrom, let tail = output.tail, let first = output.layout.lines(from: from).first {
            let top = first.entry.y + first.line.inkTop
            if output.layout.height - top <= TailRenderer.height - TailRenderer.margin - 2, top < tail.top { outsideTail += 1 }
        }
        guard step % 3 == 0 else { return }
        let document = documentDifference(output, scale: 2)
        let tail = tailDifference(output, scale: 2) ?? (0, 0)
        if document.count + tail.count > 0, mismatches.count < 3 {
            mismatches.append("step \(step), fading from \(output.hidden.fadingFrom.map(String.init) ?? "-"): document \(document), tail \(tail)")
        }
        checked += 1
    }
    #expect(checked > 10)
    // Not while a table's header waits for the line below it.
    #expect(fading * 2 > step)
    #expect(outsideTail == 0)
    #expect(mismatches.isEmpty, "\(mismatches.joined(separator: "\n"))")
}

/// Fades in right-to-left text, and in a block that turns right to left
/// when its first letter arrives, make up the text as it is drawn.
@Test(arguments: [3, 8])
func fadePiecesMakeUpRightToLeftText(chunk: Int) {
    let markdown = """
    # כותרת בעברית

    שלום עולם, זה משפט ארוך בעברית עם **מילה מודגשת** שעובר לשורה הבאה ברוחב הזה.

    > 2024: ציטוט ארוך בעברית שעובר לשורה השנייה

    English, then עברית at the end of the line.

    """
    var checked = 0
    var mismatches: [String] = []
    var step = 0
    streamFades(markdown, chunk: chunk) { output in
        step += 1
        guard step % 2 == 0 else { return }
        let document = documentDifference(output, scale: 2)
        let tail = tailDifference(output, scale: 2) ?? (0, 0)
        if document.count + tail.count > 0, mismatches.count < 3 {
            mismatches.append("step \(step), fading from \(output.hidden.fadingFrom.map(String.init) ?? "-"): document \(document), tail \(tail)")
        }
        checked += 1
    }
    #expect(checked > 10)
    #expect(mismatches.isEmpty, "\(mismatches.joined(separator: "\n"))")
}

@Test func theFrontierMovesALineAtATimeAndItsRowsAreDrawnAgain() {
    var froms: [Int?] = []
    var redraws = 0
    var outputs: [LayoutEngine.Output] = []
    // 0.04 s at 60 updates a second: a fade is in progress at the update
    // that starts it and the two after.
    streamFades(sample, chunk: 4, duration: 0.04) { output in
        if let from = froms.last ?? nil, output.hidden.fadingFrom != from {
            let end = output.hidden.fadingFrom ?? output.layout.length
            // Text that stopped fading is drawn again, if it has lines.
            if let line = output.layout.lines(from: from).first, line.entry.start + line.line.range.lowerBound < end {
                #expect(output.restyled.contains { $0.minY <= line.entry.y + line.line.frame.minY + 1 })
                redraws += 1
            }
        }
        froms.append(output.hidden.fadingFrom)
        outputs.append(output)
    }
    for (output, from) in zip(outputs, froms) {
        guard let from, let first = output.layout.lines(from: from).first else { continue }
        // No piece is above the frontier's line.
        #expect(output.fade?.pieces.allSatisfy { $0.frame.maxY > first.entry.y + first.line.frame.minY } != false)
    }
    // About once per line, not once per update.
    #expect(redraws > 5)
    #expect(redraws < froms.count / 3)
    // The frontier only moves forward while fades go on.
    for (a, b) in zip(froms, froms.dropFirst()) {
        if let a, let b { #expect(b >= a) }
    }
}

@Test func withoutADurationNothingFades() {
    streamFades(sample, chunk: 7, duration: 0) { output in
        #expect(output.hidden.fadingFrom == nil)
        #expect(output.fade == nil)
    }
}

@Test func aTagThatStartsItsAnimationEndsTheFades() {
    let hop = TranscriptTag("hop", TranscriptDecoration(animation: .custom(TestHop())))
    let engine = LayoutEngine()
    let clock = Clock()
    engine.clock = { clock.now }
    engine.setTailStyle(colors: colors, scale: 2)
    engine.setFadeDuration(10)
    engine.setAnimationsEnabled(true)
    _ = engine.relayout(width: 320, style: .init())
    var parser = MarkdownStreamParser(idPrefix: "t", tags: [hop])
    var outputs: [LayoutEngine.Output] = []
    for (index, chunk) in ["Some text and ", "<hop>a tag", "</hop>", " and more"].enumerated() {
        parser.append(chunk)
        engine.submit(.init(document: parser.document, source: 1, sequence: index + 1))
        engine.drainNow()
        if let output = engine.takeOutput() { outputs.append(output) }
        clock.now += 1.0 / 60
    }
    #expect(outputs.count == 4)
    #expect(outputs[1].hidden.fadingFrom == 0)
    // The update in which the tag closes and starts: no fades, and none from it.
    #expect(!outputs[2].started.isEmpty)
    #expect(outputs[2].hidden.fadingFrom == nil)
    #expect(outputs[2].fade == nil)
    // Text after it fades again, from where it starts.
    #expect(outputs[3].hidden.fadingFrom == outputs[2].layout.length)
}

private struct TestHop: TranscriptAnimationRecipe {
    func animation(for fragments: [TranscriptFragment]) -> TranscriptAnimation {
        var animation = TranscriptAnimation()
        for (line, fragment) in fragments.enumerated() {
            for index in fragment.glyphs.indices {
                animation.glyphs.append(.init(fragment: line, glyph: index, offsetY: .spring(peak: -3, start: 0)))
            }
        }
        return animation
    }
}

@Test func aRelayoutEndsTheFades() {
    let engine = LayoutEngine()
    engine.setTailStyle(colors: colors, scale: 2)
    engine.setFadeDuration(10)
    _ = engine.relayout(width: 320, style: .init())
    engine.submit(.init(document: MarkdownStreamParser.document(from: "Some text"), source: 1, sequence: 1))
    engine.drainNow()
    #expect(engine.takeOutput()?.hidden.fadingFrom == 0)
    _ = engine.relayout(width: 300, style: .init())
    engine.submit(.init(document: MarkdownStreamParser.document(from: "Some text, and more"), source: 1, sequence: 2))
    engine.drainNow()
    let output = engine.takeOutput()
    // Only the text after the relayout fades.
    #expect(output?.hidden.fadingFrom == 9)
    #expect(engine.endFades() == 9)
    #expect(engine.endFades() == nil)
}

@Test func whenUpdatesStopTheEngineDrawsTheFadedTextIntoTheTail() {
    let engine = LayoutEngine()
    let clock = Clock()
    engine.clock = { clock.now }
    engine.setTailStyle(colors: colors, scale: 2)
    engine.setFadeDuration(0.1)
    _ = engine.relayout(width: 320, style: .init())
    var parser = MarkdownStreamParser(idPrefix: "s")
    for (index, chunk) in ["Some text ", "that keeps ", "coming in."].enumerated() {
        parser.append(chunk)
        engine.submit(.init(document: parser.document, source: 1, sequence: index + 1))
        engine.drainNow()
        _ = engine.takeOutput()
        clock.now += 1.0 / 60
    }
    clock.now += 1
    engine.settleFinishedFades()
    engine.drainNow()
    let output = engine.takeOutput()
    #expect(output?.hidden.fadingFrom == nil)
    #expect(output?.fade == nil)
    #expect(output?.isAppend == true)
    #expect(output?.restyled.isEmpty == false)
    if let output {
        #expect(tailDifference(output, scale: 2)?.count == 0)
    }
    // Nothing more to settle.
    engine.settleFinishedFades()
    engine.drainNow()
    #expect(engine.takeOutput() == nil)
}

@Test func aRelayoutForTheImageStoreKeepsFadesThatDidNotMove() {
    let engine = LayoutEngine()
    engine.setTailStyle(colors: colors, scale: 2)
    engine.setFadeDuration(10)
    _ = engine.relayout(width: 320, style: .init())
    engine.submit(.init(document: MarkdownStreamParser.document(from: "Some text"), source: 1, sequence: 1))
    engine.drainNow()
    #expect(engine.takeOutput()?.hidden.fadingFrom == 0)
    #expect(engine.relayout(width: 320, style: .init(), keepingFades: true)?.fadingFrom == 0)
    // At another width the text moves: the fades end.
    #expect(engine.relayout(width: 200, style: .init(), keepingFades: true)?.fadingFrom == nil)
    #expect(engine.endFades() == nil)
}

/// While text streams into a paragraph, a fade's piece keeps its image from
/// one update to the next, so the view hands Core Animation only the new
/// text's image: one or two new images an update, however many fades.
@Test func piecesKeepTheirImagesWhileTheirGlyphsStayPut() {
    var previous: [ObjectIdentifier] = []
    var newImages: [Int] = []
    var piecesPerUpdate: [Int] = []
    let paragraph = String(repeating: "Words that stream into one long paragraph and wrap now and then. ", count: 6)
    streamFades(paragraph, chunk: 3, duration: 0.3) { output in
        let images = output.fade?.pieces.map { ObjectIdentifier($0.image) } ?? []
        newImages.append(images.filter { !previous.contains($0) }.count)
        piecesPerUpdate.append(images.count)
        previous = images
    }
    let updates = newImages.count
    #expect(piecesPerUpdate.dropFirst(20).allSatisfy { $0 >= 10 })
    #expect(newImages.reduce(0, +) * 10 < updates * 15)
    #expect(newImages.max() ?? 0 <= 20)
}



/// A piece is drawn again when its text's style changes in place, as when
/// a reference's definition arrives and makes it a link.
@Test func aPieceWhoseStyleChangesIsDrawnAgain() {
    let renderer = FadeRenderer()
    let before = DocumentLayout(document: MarkdownStreamParser.document(from: "See [the docs][d] here"), width: 320)
    let after = DocumentLayout(document: MarkdownStreamParser.document(from: "See [the docs][d] here\n\n[d]: https://example.com"), width: 320)
    let fade = Fade(id: 1, range: 0..<before.length, start: 0)
    let first = renderer.render(before, from: 0, fades: [fade], colors: colors, scale: 2, playing: [])
    let same = renderer.render(before, from: 0, fades: [fade], colors: colors, scale: 2, playing: [])
    let restyled = renderer.render(after, from: 0, fades: [fade], colors: colors, scale: 2, playing: [])
    #expect(first?.pieces.first?.image === same?.pieces.first?.image)
    #expect(first?.pieces.first?.image !== restyled?.pieces.first?.image)
}
