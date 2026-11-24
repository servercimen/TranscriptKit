import CoreGraphics
import CoreText
import Foundation
import IOSurface
import QuartzCore
import Testing
@testable import TranscriptKit

// MARK: Definitions

private let band = TranscriptDecoration.Shape.underline(.marker, color: TranscriptColor(red: 1, green: 0.8, blue: 0, alpha: 0.5))
private let pill = TranscriptDecoration.Shape.pill(fill: TranscriptColor(red: 0.3, green: 0.3, blue: 0.9, alpha: 0.2))

/// Sweeps in the tag's own shapes and makes each glyph hop.
private struct Hop: TranscriptAnimationRecipe {
    var shapes: [TranscriptDecoration.Shape]

    func animation(for fragments: [TranscriptFragment]) -> TranscriptAnimation {
        var animation = TranscriptAnimation()
        for (line, fragment) in fragments.enumerated() {
            for shape in shapes {
                for path in shape.paths(for: fragment) {
                    animation.paths.append(.init(fragment: line, path: path, reveal: .ramp(from: 0, to: 1, start: 0.05, duration: 0.3)))
                }
            }
            for index in fragment.glyphs.indices {
                animation.glyphs.append(.init(fragment: line, glyph: index, offsetY: .spring(peak: -3, start: 0.1 + Double(index) * 0.02)))
            }
        }
        return animation
    }
}

private let tags: [TranscriptTag] = [
    TranscriptTag("hop", TranscriptDecoration(shapes: [band], animation: .custom(Hop(shapes: [band])))),
    TranscriptTag("chip", TranscriptDecoration(foreground: TranscriptColor(red: 0.8, green: 0, blue: 0), padding: 4, shapes: [pill],
                                               animation: .custom(Hop(shapes: [pill])))),
    TranscriptTag("still", TranscriptDecoration(shapes: [band])),
]

private func document(_ markdown: String) -> TranscriptDocument {
    MarkdownStreamParser.document(from: markdown, idPrefix: "a", tags: tags)
}

/// The document after each chunk of `markdown`, as a stream gives them.
private func steps(_ markdown: String, chunk: Int) -> [TranscriptDocument] {
    var parser = MarkdownStreamParser(idPrefix: "a", tags: tags)
    var documents: [TranscriptDocument] = []
    var rest = Substring(markdown)
    while !rest.isEmpty {
        parser.append(String(rest.prefix(chunk)))
        rest = rest.dropFirst(chunk)
        documents.append(parser.document)
    }
    parser.finish()
    documents.append(parser.document)
    return documents
}

private func animatedFragments(_ layout: DocumentLayout) -> [AnimatedFragment] {
    (0..<layout.entryCount).flatMap { layout.entry(at: $0).layout.lines.flatMap { $0.decorations?.animated ?? [] } }
}

// MARK: Waiting for the closing tag

@Test func animatedTagsWaitForTheirClosingTag() throws {
    var parser = MarkdownStreamParser(idPrefix: "a", tags: tags)
    parser.append("Fixed the <hop>login time")
    let open = try #require(parser.document.blocks[0].spans.first { $0.customTag?.name == "hop" }?.customTag)
    #expect(open.isOpen)
    parser.append("outs</hop> today")
    let closed = try #require(parser.document.blocks[0].spans.first { $0.customTag?.name == "hop" }?.customTag)
    #expect(!closed.isOpen)

    // A tag without an animation looks the same either way, and isn't marked.
    parser.append(" and <still>more")
    let still = try #require(parser.document.blocks[0].spans.first { $0.customTag?.name == "still" }?.customTag)
    #expect(!still.isOpen)

    // A tag left open in a finished paragraph has closed for good.
    let finished = document("Fixed the <hop>login timeouts\n\nNext")
    #expect(finished.blocks[0].spans.contains { $0.customTag?.name == "hop" && $0.customTag?.isOpen == false })
}

@Test func anOpenAnimatedTagShowsItsTextButNotItsShapes() throws {
    var parser = MarkdownStreamParser(idPrefix: "a", tags: tags)
    parser.append("Fixed the <hop>login timeouts")
    let open = DocumentLayout(document: parser.document, width: 320)
    let line = open.entry(at: 0).layout.lines[0]
    #expect(line.decorations?.behind.isEmpty ?? true)
    #expect(animatedFragments(open).isEmpty)

    // Closed with no new text: the line is laid out again, with its shapes
    // and its glyphs for the animation, not reused as it was.
    parser.append("</hop>")
    let closed = DocumentLayout(document: parser.document, width: 320, reusing: open)
    let decorations = try #require(closed.entry(at: 0).layout.lines[0].decorations)
    #expect(decorations.behind.count == 1)
    #expect(decorations.behindTags.count == 1 && decorations.behindTags[0] != nil)
    let fragment = try #require(decorations.animated.first)
    #expect(fragment.fragment.glyphs.count == "login timeouts".count)
    #expect(fragment.fragment.glyphs.map(\.index) == Array(0..<"login timeouts".utf16.count))
    // Each glyph's box sits inside the tag's text.
    for glyph in fragment.fragment.glyphs {
        #expect(glyph.bounds.minX >= fragment.fragment.textRect.minX - 0.01)
        #expect(glyph.bounds.maxX <= fragment.fragment.textRect.maxX + 0.01)
    }
}

/// Streamed in any chunks, the layout ends the same as one made from scratch.
@Test(arguments: [1, 3, 7])
func streamedAnimatedTagsLayOutLikeAFreshLayout(chunk: Int) {
    let markdown = "Fixed the <hop>login timeouts that support flagged on Monday</hop> and <chip>@ana</chip> took it. " +
        "Then <hop>a second one</hop>.\n\n<hop>Starts a paragraph</hop> and ends it."
    var layout: DocumentLayout?
    for step in steps(markdown, chunk: chunk) {
        layout = DocumentLayout(document: step, width: 240, reusing: layout)
    }
    let fresh = DocumentLayout(document: document(markdown), width: 240)
    func signature(_ layout: DocumentLayout) -> [String] {
        (0..<layout.entryCount).flatMap { index in
            layout.entry(at: index).layout.lines.map { line in
                let animated = line.decorations?.animated.map { "\($0.key.start):\($0.fragment.glyphs.count):\($0.fragment.textRect)" } ?? []
                return "\(line.range) \(line.frame) \(line.decorations?.behind.count ?? 0) \(animated)"
            }
        }
    }
    #expect(signature(layout!) == signature(fresh))
}

// MARK: Starting

private let colors = TailRenderer.Colors(text: CGColor(gray: 0, alpha: 1), codeBackground: CGColor(gray: 0.9, alpha: 1),
                                         accent: CGColor(gray: 0.6, alpha: 1))

@Test func theEngineStartsATagsAnimationWhenItCloses() throws {
    let engine = LayoutEngine()
    engine.setTailStyle(colors: colors, scale: 2)
    engine.setAnimationsEnabled(true)
    // Earlier text with a closed tag: shown at rest.
    var parser = MarkdownStreamParser(idPrefix: "e", tags: tags)
    parser.append("Earlier <hop>done</hop> text.\n\nNow the <hop>login")
    engine.submit(.init(document: parser.document, source: 1, sequence: 1))
    _ = try #require(engine.relayout(width: 300, style: TranscriptStyle()))

    var sequence = 2
    func append(_ text: String) throws -> LayoutEngine.Output {
        parser.append(text)
        engine.submit(.init(document: parser.document, source: 1, sequence: sequence))
        sequence += 1
        engine.drainNow()
        return try #require(engine.takeOutput())
    }
    #expect(try append(" timeouts").started.isEmpty)
    let closing = try append("</hop> on")
    #expect(closing.started == [TagKey(block: "e-1", start: 8, name: "hop")])
    #expect(closing.hidden == TagHiding(playing: Set(closing.started)))
    // Its rows are drawn again, without it.
    #expect(!closing.restyled.isEmpty)

    // Not again on later updates, but still hidden until the view is done.
    let later = try append(" Monday.")
    #expect(later.started.isEmpty)
    #expect(later.hidden == TagHiding(playing: Set(closing.started)))
    engine.settleAnimations(closing.started)
    #expect(try append(" More.").hidden.isEmpty)

    // A tag that arrives whole in one update starts too.
    #expect(try append(" And <hop>quick</hop>.").started.count == 1)

    // Turned off, nothing starts.
    engine.setAnimationsEnabled(false)
    #expect(try append(" And <hop>off</hop>.").started.isEmpty)

    // A replaced document starts nothing; a relayout forgets what played.
    engine.setAnimationsEnabled(true)
    _ = try append(" <hop>pending")
    engine.submit(.init(document: document("Other <hop>text</hop>."), source: 1, sequence: sequence))
    engine.drainNow()
    #expect(try #require(engine.takeOutput()).started.isEmpty)
}

// MARK: Drawing

private func render(_ layout: DocumentLayout, hiding: TagHiding = .none, sprites: [TagAnimationPlayer.Sprite] = [],
                    scale: CGFloat = 2) -> [UInt8] {
    let width = Int((layout.width * scale).rounded())
    let height = Int(((layout.height + 12) * scale).rounded())
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: scale, y: -scale)
    let all = CGRect(x: 0, y: 0, width: layout.width, height: layout.height + 12)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(all)
    layout.draw(in: context, dirtyRect: all, text: colors.text, codeBackground: colors.codeBackground, accent: colors.accent,
                dark: false, highContrast: false, hiding: hiding)
    // Sprites at rest, as their layers show them: upright, at their frames.
    for sprite in sprites {
        context.saveGState()
        context.translateBy(x: sprite.frame.minX, y: sprite.frame.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(sprite.image, in: CGRect(origin: .zero, size: sprite.frame.size))
        context.restoreGState()
    }
    return Array(UnsafeRawBufferPointer(start: context.data!, count: width * height * 4))
}

/// Rows (in points) where two renders differ by more than `tolerance`.
private func differingRows(_ a: [UInt8], _ b: [UInt8], width: CGFloat, scale: CGFloat = 2, tolerance: Int = 0) -> [CGFloat] {
    let rowBytes = Int((width * scale).rounded()) * 4
    var rows: [CGFloat] = []
    for row in 0..<(a.count / rowBytes) {
        let range = (row * rowBytes)..<((row + 1) * rowBytes)
        if zip(a[range], b[range]).contains(where: { abs(Int($0) - Int($1)) > tolerance }) { rows.append(CGFloat(row) / scale) }
    }
    return rows
}

private let sample = "Before it. Fixed the <hop>login timeouts that support flagged on Monday</hop>, then <chip>@ana</chip> took it.\n\nAfter."

@Test func aPlayingTagIsLeftOutOfTheDrawingAndNothingElse() throws {
    let layout = DocumentLayout(document: document(sample), width: 260)
    let key = TagKey(block: "a-0", start: 21, name: "hop")
    let tag = try #require(layout.animatedTag(key))
    #expect(tag.parts.count == 2) // it wraps
    let whole = render(layout)
    let hidden = render(layout, hiding: TagHiding(playing: [key]))
    let rows = differingRows(whole, hidden, width: layout.width)
    #expect(!rows.isEmpty)
    #expect(rows.allSatisfy { tag.band.contains($0) }, "differs outside the tag's rows: \(rows.filter { !tag.band.contains($0) })")

    // Nothing dark is left inside the tag's glyph boxes.
    let scale: CGFloat = 2
    let rowBytes = Int((layout.width * scale).rounded()) * 4
    var dark = 0
    for part in tag.parts {
        for glyph in part.fragment.fragment.glyphs {
            let box = glyph.bounds.offsetBy(dx: part.origin.x, dy: part.origin.y).insetBy(dx: 0.5, dy: 0.5)
            for y in Int(box.minY * scale)..<Int(box.maxY * scale) {
                for x in Int(box.minX * scale)..<Int(box.maxX * scale) where hidden[y * rowBytes + x * 4] < 100 { dark += 1 }
            }
        }
    }
    #expect(dark == 0)
}

/// The handoff: the animation's sprites at rest, drawn over the text left
/// without the tag, give the pixels of the text drawn whole. So when the
/// animation ends and the view draws the tag again, nothing moves.
@Test(arguments: [2, 3] as [CGFloat])
func spritesAtRestRedrawTheTagExactly(scale: CGFloat) throws {
    let layout = DocumentLayout(document: document(sample), width: 260)
    for key in [TagKey(block: "a-0", start: 21, name: "hop"), TagKey(block: "a-0", start: 73, name: "chip")] {
        let tag = try #require(layout.animatedTag(key), "\(key)")
        let animation = tag.animation.animation(for: tag.fragments)
        #expect(animation.duration > 0.3)
        let sprites = TagAnimationPlayer.sprites(for: tag, animation: animation,
                                                 appearance: .init(text: colors.text, dark: false, scale: scale))
        let glyphCount = tag.parts.reduce(0) { $0 + $1.fragment.fragment.glyphs.count }
        #expect(sprites.filter { if case .glyph = $0.kind { true } else { false } }.count == glyphCount)
        let whole = render(layout, scale: scale)
        let handedOff = render(layout, hiding: TagHiding(playing: [key]), sprites: sprites, scale: scale)
        let rows = differingRows(whole, handedOff, width: layout.width, scale: scale, tolerance: 2)
        #expect(rows.isEmpty, "\(key.name): \(rows.count) rows differ, first \(rows.first ?? -1)")
    }
}

@Test func theTailLeavesOutPlayingTagsLikeTheTiles() throws {
    let markdown = "Fixed the <hop>login timeouts that support flagged on Monday</hop> and more text after it."
    let renderer = TailRenderer(colors: colors, scale: 2)
    var layout: DocumentLayout?
    var frame: TailRenderer.Frame?
    let key = TagKey(block: "a-0", start: 10, name: "hop")
    for step in steps(markdown, chunk: 6) {
        let next = DocumentLayout(document: step, width: 260, reusing: layout)
        var changedTop: CGFloat?
        var restyled: [CGRect] = []
        if let layout { (changedTop, restyled) = next.changes(since: layout) }
        if let layout, next.newlyClosedAnimatedTags(since: layout) == [key], let tag = next.animatedTag(key) {
            restyled.append(CGRect(x: 0, y: tag.band.lowerBound, width: next.width, height: tag.band.upperBound - tag.band.lowerBound))
        }
        frame = renderer.render(next, changedTop: changedTop, restyled: restyled,
                                hiding: next.animatedTag(key) == nil ? .none : TagHiding(playing: [key]))
        layout = next
    }
    let tail = try #require(frame)
    let final = try #require(layout)
    let pixels = try #require(renderer.currentPixels())
    // The same layout drawn in one go, without the tag, into a strip like the tail's.
    let width = Int(((final.width + 2 * TailRenderer.sideMargin) * 2).rounded())
    let height = Int((TailRenderer.height * 2).rounded())
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 2, y: -2)
    context.translateBy(x: TailRenderer.sideMargin, y: -tail.top)
    final.draw(in: context, dirtyRect: CGRect(x: -TailRenderer.sideMargin, y: tail.top, width: final.width + 2 * TailRenderer.sideMargin,
                                              height: TailRenderer.height),
               text: colors.text, codeBackground: colors.codeBackground, accent: colors.accent, dark: false, highContrast: false, hiding: TagHiding(playing: [key]))
    let expected = Array(UnsafeRawBufferPointer(start: context.data!, count: width * height * 4))
    #expect(zip(pixels, expected).allSatisfy { abs(Int($0) - Int($1)) <= 2 })
}

// MARK: Curves

@Test func springsLeaveRestReachTheirPeakAndComeBack() {
    let spring = TranscriptCurve.spring(peak: -4, start: 0.2, frequency: 4, damping: 0.3)
    #expect(spring.value(at: 0) == 0)
    #expect(spring.value(at: 0.2) == 0)
    let lowest = spring.values.min()!
    #expect(abs(lowest - -4) < 0.15)
    // It swings back past rest, less far.
    let highest = spring.values.max()!
    #expect(highest > 0.5 && highest < 4)
    #expect(spring.values.last == 0)
    #expect(spring.value(at: 10) == 0)
    #expect(spring.endTime > 0.5 && spring.endTime < 2.5)
}

@Test func rampsAndCurvesInterpolate() {
    let ramp = TranscriptCurve.ramp(from: 0, to: 10, start: 1, duration: 2)
    #expect(ramp.value(at: 0) == 0)
    #expect(abs(ramp.value(at: 2) - 5) < 0.001)
    #expect(ramp.value(at: 4) == 10)
    let eased = TranscriptCurve.ramp(from: 0, to: 1, duration: 1, easing: .easeIn)
    #expect(eased.value(at: 0.5) < 0.2)
    #expect(TranscriptCurve.Easing.easeInOut.inverse(0.5) > 0.49 && TranscriptCurve.Easing.easeInOut.inverse(0.5) < 0.51)
    let doubled = ramp.map { $0 * 2 }.delayed(by: 1)
    #expect(abs(doubled.value(at: 3) - 10) < 0.001)
    let animation = TranscriptAnimation(glyphs: [.init(fragment: 0, glyph: 0, offsetY: ramp)],
                                        paths: [.init(fragment: 0, path: TranscriptPath(CGPath(rect: .zero, transform: nil)), opacity: doubled)])
    #expect(animation.duration == 4)
}

@Test func animationsAreValues() {
    let a = TranscriptDecoration(animation: .custom(Hop(shapes: [band])))
    let b = TranscriptDecoration(animation: .custom(Hop(shapes: [band])))
    let c = TranscriptDecoration(animation: .custom(Hop(shapes: [pill])))
    #expect(a == b)
    #expect(a != c)
    #expect(a != TranscriptDecoration())
}

/// Text that streams in right after a tag can change its last glyph's
/// advance (a kerning pair such as "y."), but not where any of its glyphs
/// are drawn: a playing animation carries on.
@Test(arguments: [".", ",", "'s", " and more"])
func textAfterATagKeepsItsAnimationGoing(next: String) throws {
    var parser = MarkdownStreamParser(idPrefix: "a", tags: tags)
    parser.append("Fixed the <hop>login timeouts that support flagged on Monday</hop>")
    let closed = DocumentLayout(document: parser.document, width: 260)
    parser.append(next)
    let later = DocumentLayout(document: parser.document, width: 260, reusing: closed)
    let key = TagKey(block: "a-0", start: 10, name: "hop")
    let before = try #require(closed.animatedTag(key))
    let after = try #require(later.animatedTag(key))
    #expect(before.isPlaced(like: after))
}

// MARK: Timing

@Test func aStreamSaysWhenItHasFinished() throws {
    let worker = StreamWorker(parser: MarkdownStreamParser(idPrefix: "w", tags: tags))
    let first = try #require(worker.queue.sync { worker.apply("Some text", finish: false) })
    #expect(!first.isFinished)
    // Finishing changes nothing visible here, and is still an update.
    let finished = try #require(worker.queue.sync { worker.apply("", finish: true) })
    #expect(finished.isFinished && finished.document == first.document && finished.sequence > first.sequence)
    #expect(worker.queue.sync { worker.apply("", finish: true) } == nil)
    // More text: not finished any more.
    let more = try #require(worker.queue.sync { worker.apply(" and more", finish: false) })
    #expect(!more.isFinished)
}

/// A tag waiting to play is drawn as it was while open: its text without its shapes.
@Test func aWaitingTagLooksAsItDidWhileOpen() throws {
    var parser = MarkdownStreamParser(idPrefix: "a", tags: tags)
    parser.append("Before it. Fixed the <hop>login timeouts that support flagged on Monday")
    let open = DocumentLayout(document: parser.document, width: 260)
    parser.append("</hop>")
    let closed = DocumentLayout(document: parser.document, width: 260, reusing: open)
    let key = TagKey(block: "a-0", start: 21, name: "hop")
    #expect(closed.animatedTag(key) != nil)
    #expect(render(closed, hiding: TagHiding(waiting: [key])) == render(open))
    #expect(render(closed) != render(open))
}

@Test func theEngineCanLeaveTagsWaitingForTheView() throws {
    let engine = LayoutEngine()
    engine.setTailStyle(colors: colors, scale: 2)
    engine.setAnimationsEnabled(true, immediately: false)
    var parser = MarkdownStreamParser(idPrefix: "e", tags: tags)
    parser.append("Now the <hop>login")
    engine.submit(.init(document: parser.document, source: 1, sequence: 1))
    _ = try #require(engine.relayout(width: 300, style: TranscriptStyle()))
    var sequence = 2
    func append(_ text: String, finished: Bool = false) throws -> LayoutEngine.Output {
        parser.append(text)
        engine.submit(.init(document: parser.document, source: 1, sequence: sequence, isFinished: finished))
        sequence += 1
        engine.drainNow()
        return try #require(engine.takeOutput())
    }
    let key = TagKey(block: "e-0", start: 8, name: "hop")
    let closing = try append(" timeouts</hop> on")
    #expect(closing.started.isEmpty)
    #expect(closing.waiting == [key])
    #expect(closing.hidden == TagHiding(waiting: [key]))
    #expect(!closing.isFinished)

    // The tail shows the tag's text without its shapes.
    let tail = try #require(closing.tail)
    let renderer = TailRenderer(colors: colors, scale: 2)
    _ = renderer.render(closing.layout, changedTop: nil, hiding: TagHiding(waiting: [key]))
    let expected = try #require(renderer.currentPixels())
    let shown = try #require(TailRendererProbe.pixels(of: tail.surface))
    #expect(zip(shown, expected).allSatisfy { abs(Int($0) - Int($1)) <= 2 })

    // Started by the view: from then on the tail leaves it out entirely.
    engine.playAnimations([key])
    #expect(try append(" Monday.").hidden == TagHiding(playing: [key]))
    engine.settleAnimations([key])
    let last = try append(" Done.", finished: true)
    #expect(last.hidden.isEmpty)
    #expect(last.isFinished)
    #expect(try #require(engine.relayout(width: 300, style: TranscriptStyle())).isFinished)
}

/// Reads an IOSurface's rows without their padding.
private enum TailRendererProbe {
    static func pixels(of surface: IOSurface) -> [UInt8]? {
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let width = surface.width
        var result: [UInt8] = []
        for row in 0..<surface.height {
            result.append(contentsOf: UnsafeRawBufferPointer(start: surface.baseAddress + row * surface.bytesPerRow, count: width * 4))
        }
        return result
    }
}

/// A stream that finishes is often replaced by its document straight away
/// (a new source). If the stream's last layout is still in the mailbox, the
/// document's layout builds on it, so the two are merged: the view, which
/// never saw the stream's last layout, still gets an append it can apply,
/// and tags keep waiting or playing instead of being drawn at rest.
@Test func aNewSourceThatContinuesTheTextStaysAnAppend() throws {
    let engine = LayoutEngine()
    engine.setAnimationsEnabled(true, immediately: false)
    var parser = MarkdownStreamParser(idPrefix: "s", tags: tags)
    parser.append("Fixed the <hop>login")
    engine.submit(.init(document: parser.document, source: 1, sequence: 1))
    let installed = try #require(engine.relayout(width: 300, style: TranscriptStyle())).layout
    parser.append(" timeouts</hop> today.")
    engine.submit(.init(document: parser.document, source: 1, sequence: 2))
    engine.drainNow()
    // Not taken yet: the stream ends and the view switches to its document.
    parser.finish()
    engine.submit(.init(document: parser.document, source: 2, sequence: 1, isFinished: true))
    engine.drainNow()
    let output = try #require(engine.takeOutput())
    #expect(output.source == 2)
    #expect(output.base === installed)
    #expect(output.isAppend)
    #expect(output.isFinished)
    #expect(output.waiting == [TagKey(block: "s-0", start: 10, name: "hop")])
}

/// The player's layers need no offscreen passes: no masks, shadows or group
/// opacity, and the reveal clips each band to its own (rectangular) bounds.
@Test func animationLayersNeedNoOffscreenPasses() throws {
    let layout = DocumentLayout(document: document(sample), width: 260)
    let tag = try #require(layout.animatedTag(TagKey(block: "a-0", start: 21, name: "hop")))
    let animation = tag.animation.animation(for: tag.fragments)
    let sprites = TagAnimationPlayer.sprites(for: tag, animation: animation, appearance: .init(text: colors.text, dark: false, scale: 3))
    let container = TagAnimationPlayer.makeLayer(sprites: sprites, animation: animation, scale: 3, beginTime: 0)
    let layers = container.sublayers ?? []
    #expect(layers.count == sprites.count)
    // Nothing animates implicitly, so the view needs no transaction of its own.
    #expect(container.action(forKey: "sublayers") is NSNull)
    #expect(container.action(forKey: kCAOnOrderIn) is NSNull)
    for layer in layers {
        #expect(layer.action(forKey: "position") is NSNull && layer.action(forKey: "bounds") is NSNull)
        #expect(layer.mask == nil)
        #expect(layer.shadowOpacity == 0)
        #expect(layer.sublayers?.isEmpty ?? true)
        #expect(layer.cornerRadius == 0)
    }
    // At rest each band layer sits exactly on its sprite's frame.
    for (layer, sprite) in zip(layers, sprites) {
        #expect(abs(layer.frame.minX - sprite.frame.minX) < 0.001 && abs(layer.frame.width - sprite.frame.width) < 0.001)
        #expect(abs(layer.frame.minY - sprite.frame.minY) < 0.001 && abs(layer.frame.height - sprite.frame.height) < 0.001)
    }
}
