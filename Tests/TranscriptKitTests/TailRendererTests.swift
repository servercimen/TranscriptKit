import CoreGraphics
import Foundation
import IOSurface
import Testing
@testable import TranscriptKit

private let colors = TailRenderer.Colors(
    text: CGColor(gray: 0, alpha: 1),
    codeBackground: CGColor(gray: 0.9, alpha: 1),
    accent: CGColor(gray: 0.6, alpha: 1)
)

/// The surface's pixels, row by row without padding.
private func pixels(of surface: IOSurface, width: Int, height: Int) -> [UInt8] {
    surface.lock(options: .readOnly, seed: nil)
    defer { surface.unlock(options: .readOnly, seed: nil) }
    var result: [UInt8] = []
    result.reserveCapacity(width * height * 4)
    for row in 0..<height {
        let start = surface.baseAddress + row * surface.bytesPerRow
        result.append(contentsOf: UnsafeRawBufferPointer(start: start, count: width * 4))
    }
    return result
}

/// What the tail at `top` should look like: `layout` drawn in one go.
private func expectedPixels(_ layout: DocumentLayout, top: CGFloat, scale: CGFloat) -> [UInt8] {
    let width = Int(((layout.width + 2 * TailRenderer.sideMargin) * scale).rounded())
    let height = Int((TailRenderer.height * scale).rounded())
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: scale, y: -scale)
    // The strip reaches past the column by its side margin, where shapes may draw.
    context.translateBy(x: TailRenderer.sideMargin, y: -top)
    let band = CGRect(x: -TailRenderer.sideMargin, y: top, width: layout.width + 2 * TailRenderer.sideMargin, height: TailRenderer.height)
    context.clip(to: band)
    layout.draw(in: context, dirtyRect: band, text: colors.text, codeBackground: colors.codeBackground, accent: colors.accent)
    return Array(UnsafeRawBufferPointer(start: context.data!, count: width * height * 4))
}

/// Streams `markdown` through the parser, layout and tail renderer the way
/// the layout engine does, calling `check` with every frame.
private func streamTail(_ markdown: String, chunk: Int, scale: CGFloat = 2,
                        check: (DocumentLayout, TailRenderer.Frame) -> Void) {
    var parser = MarkdownStreamParser(idPrefix: "t")
    let renderer = TailRenderer(colors: colors, scale: scale)
    var previous: DocumentLayout?
    var rest = Substring(markdown)
    while !rest.isEmpty {
        parser.append(String(rest.prefix(chunk)))
        rest = rest.dropFirst(chunk)
        let layout = DocumentLayout(document: parser.document, width: 320, reusing: previous)
        var changedTop: CGFloat?
        var restyled: [CGRect] = []
        if let previous, layout.document.extends(previous.document) {
            (changedTop, restyled) = layout.changes(since: previous)
        }
        if let frame = renderer.render(layout, changedTop: changedTop, restyled: restyled) {
            check(layout, frame)
        }
        previous = layout
    }
}

/// Drawing only what changed, frame after frame, into rotating surfaces
/// gives the same pixels as drawing the tail in one go.
@Test(arguments: [3, 17])
func tailFramesMatchADrawingFromScratch(chunk: Int) {
    let scale: CGFloat = 2
    var checked = 0
    var mismatches: [String] = []
    var frameIndex = 0
    streamTail((1...2).map(answerSection).joined(), chunk: chunk, scale: scale) { layout, frame in
        frameIndex += 1
        guard frameIndex % 7 == 0 else { return }
        let width = Int(((layout.width + 2 * TailRenderer.sideMargin) * scale).rounded())
        let height = Int((TailRenderer.height * scale).rounded())
        let actual = pixels(of: frame.surface, width: width, height: height)
        let expected = expectedPixels(layout, top: frame.top, scale: scale)
        let identical = actual.count == expected.count && actual.withUnsafeBytes { a in
            expected.withUnsafeBytes { b in memcmp(a.baseAddress!, b.baseAddress!, a.count) == 0 }
        }
        let differing = identical ? 0 : zip(actual, expected).filter { abs(Int($0) - Int($1)) > 2 }.count
        if differing > 0, mismatches.count < 3 {
            mismatches.append("frame \(frameIndex), top \(frame.top): \(differing) bytes differ")
        }
        checked += 1
    }
    #expect(checked > 10)
    #expect(mismatches.isEmpty, "\(mismatches.joined(separator: "\n"))")
}

@Test func tailStaysUntilTheTextNearsItsBottom() {
    var tops: [CGFloat] = []
    var lastHeight: CGFloat = 0
    streamTail(answerSection(1), chunk: 5) { layout, frame in
        if let last = tops.last, frame.top != last {
            // It moved because the text got near the bottom of the strip,
            // and it moved to the last line.
            #expect(lastHeight > last + TailRenderer.height - TailRenderer.margin || layout.height > last + TailRenderer.height - TailRenderer.margin)
            #expect(frame.top == TailRenderer.lastLineTop(of: layout, scale: 2))
        }
        #expect(layout.height <= frame.top + TailRenderer.height)
        tops.append(frame.top)
        lastHeight = layout.height
    }
    let moves = zip(tops, tops.dropFirst()).filter { $0 != $1 }.count
    #expect(moves >= 1)
    // Most frames keep the strip where it was.
    #expect(moves * 10 < tops.count)
}

@Test func surfacesHandedOutAreNotRefilledStraightAway() {
    var recent: [ObjectIdentifier] = []
    var surfaces = Set<ObjectIdentifier>()
    streamTail(answerSection(1), chunk: 4) { _, frame in
        let id = ObjectIdentifier(frame.surface)
        #expect(!recent.contains(id))
        recent.append(id)
        if recent.count > 2 { recent.removeFirst() }
        surfaces.insert(id)
    }
    // A small pool is reused.
    #expect(surfaces.count <= 4)
}

@Test func layoutEngineDrawsTheTailOnlyWhileAppending() throws {
    let engine = LayoutEngine()
    engine.setTailStyle(colors: colors, scale: 2)
    var parser = MarkdownStreamParser(idPrefix: "e")
    parser.append("First paragraph.\n\nSecond")
    engine.submit(.init(document: parser.document, source: 1, sequence: 1))
    _ = try #require(engine.relayout(width: 300, style: TranscriptStyle()))

    // A replaced document: no tail.
    engine.submit(.init(document: MarkdownStreamParser.document(from: "Other text"), source: 1, sequence: 2))
    engine.drainNow()
    #expect(try #require(engine.takeOutput()).tail == nil)

    // Appends: a tail, covering the end of the text.
    parser = MarkdownStreamParser(idPrefix: "e")
    parser.append("Other text")
    var sequence = 3
    for chunk in [" grows", " and grows", " some more."] {
        parser.append(chunk)
        engine.submit(.init(document: parser.document, source: 1, sequence: sequence))
        sequence += 1
        engine.drainNow()
    }
    let output = try #require(engine.takeOutput())
    let tail = try #require(output.tail)
    #expect(tail.top <= output.layout.height)

    // Settled: the next change has no tail until text is appended again.
    engine.settleTail()
    engine.submit(.init(document: MarkdownStreamParser.document(from: "Replaced"), source: 1, sequence: sequence))
    engine.drainNow()
    #expect(try #require(engine.takeOutput()).tail == nil)

    // No style (no window): never a tail.
    engine.setTailStyle(colors: nil, scale: 2)
    parser = MarkdownStreamParser(idPrefix: "f")
    parser.append("Replaced")
    engine.submit(.init(document: parser.document, source: 1, sequence: sequence + 1))
    parser.append(" more")
    engine.submit(.init(document: parser.document, source: 1, sequence: sequence + 2))
    engine.drainNow()
    #expect(try #require(engine.takeOutput()).tail == nil)
}

/// The same for tables, task lists, nested quotes and strikethrough. A table
/// keeps its unchanged rows while it streams and reports a change only from
/// the row being written, so a tall table checks that narrower region.
@Test(arguments: [2, 9])
func tailFramesMatchWithTablesAndContainers(chunk: Int) {
    let rows = (1...14).map { "| row \($0) | \(String(repeating: "word ", count: $0 % 5 + 1))| ~~\($0)~~ |" }
    let markdown = """
    Intro paragraph.

    - [x] done task
    - [ ] open task with **bold**

    > quote
    >
    > > nested quote that wraps onto a second line at this width

    | Name | Words | Old |
    | --- | :---: | ---: |
    \(rows.joined(separator: "\n"))

    After the table.

    """
    let scale: CGFloat = 2
    var checked = 0
    var mismatches: [String] = []
    var frameIndex = 0
    streamTail(markdown, chunk: chunk, scale: scale) { layout, frame in
        frameIndex += 1
        guard frameIndex % 3 == 0 else { return }
        let width = Int(((layout.width + 2 * TailRenderer.sideMargin) * scale).rounded())
        let height = Int((TailRenderer.height * scale).rounded())
        let actual = pixels(of: frame.surface, width: width, height: height)
        let expected = expectedPixels(layout, top: frame.top, scale: scale)
        let differing = zip(actual, expected).filter { abs(Int($0) - Int($1)) > 2 }.count
        if differing > 0, mismatches.count < 3 {
            mismatches.append("frame \(frameIndex), top \(frame.top): \(differing) bytes differ")
        }
        checked += 1
    }
    #expect(checked > 10)
    #expect(mismatches.isEmpty, "\(mismatches.joined(separator: "\n"))")
}

/// Right-to-left text, and a block that turns right to left when its first
/// letter arrives, stream into the tail as they draw from scratch.
@Test(arguments: [2, 7])
func tailFramesMatchInRightToLeftText(chunk: Int) {
    let markdown = """
    שלום עולם, זה משפט ארוך בעברית שעובר לשורה הבאה ברוחב הזה.

    > 2024: מרחבא בעולם, וזה ציטוט ארוך

    - פריט ראשון ברשימה
    - [ ] משימה פתוחה

    | מילה | פירוש |
    | --- | --- |
    | אחת | ראשונה |

    English, then עברית at the end.

    """
    let scale: CGFloat = 2
    var checked = 0
    var mismatches: [String] = []
    var frameIndex = 0
    streamTail(markdown, chunk: chunk, scale: scale) { layout, frame in
        frameIndex += 1
        let width = Int(((layout.width + 2 * TailRenderer.sideMargin) * scale).rounded())
        let height = Int((TailRenderer.height * scale).rounded())
        let actual = pixels(of: frame.surface, width: width, height: height)
        let expected = expectedPixels(layout, top: frame.top, scale: scale)
        let differing = zip(actual, expected).filter { abs(Int($0) - Int($1)) > 2 }.count
        if differing > 0, mismatches.count < 3 {
            mismatches.append("frame \(frameIndex), top \(frame.top): \(differing) bytes differ")
        }
        checked += 1
    }
    #expect(checked > 10)
    #expect(mismatches.isEmpty, "\(mismatches.joined(separator: "\n"))")
}

/// Rows already written keep their lines while a table streams, as long as
/// the columns stay the same.
@Test func streamingTableKeepsFinishedRows() throws {
    var parser = MarkdownStreamParser(idPrefix: "t")
    parser.append("| a | a longer header |\n| --- | --- |\n| one | two |\n| three | fo")
    let before = DocumentLayout(document: parser.document, width: 320)
    parser.append("ur |\n| x")
    let after = DocumentLayout(document: parser.document, width: 320, reusing: before)
    let old = try #require(before.entry(at: 0).layout)
    let new = try #require(after.entry(at: 0).layout)
    let oldTable = try #require(old.table)
    let newTable = try #require(new.table)
    #expect(oldTable.columnX == newTable.columnX)
    // Header and the first body row are the same lines.
    for index in 0..<oldTable.cellLines[1].last!.upperBound {
        #expect(new.lines[index].ctLine === old.lines[index].ctLine)
    }
    // The change starts just above the row that was being written.
    #expect(after.firstChangedY(since: before) == newTable.rowY[2] - BlockLayout.Table.changeMargin)
}

/// A reference link is styled once its definition arrives, which may be
/// blocks later; the tail is then redrawn from the block that changed.
@Test(arguments: [1, 4])
func tailRestylesReferencesWhenDefined(chunk: Int) {
    let markdown = """
    See [the guide][g] and the note [1].

    A paragraph in between.

    [g]: https://guide.example
    [1]: https://one.example

    After the definitions.

    """
    let scale: CGFloat = 2
    var checked = 0
    var mismatches: [String] = []
    var frameIndex = 0
    streamTail(markdown, chunk: chunk, scale: scale) { layout, frame in
        frameIndex += 1
        let width = Int(((layout.width + 2 * TailRenderer.sideMargin) * scale).rounded())
        let height = Int((TailRenderer.height * scale).rounded())
        let actual = pixels(of: frame.surface, width: width, height: height)
        let expected = expectedPixels(layout, top: frame.top, scale: scale)
        let differing = zip(actual, expected).filter { abs(Int($0) - Int($1)) > 2 }.count
        if differing > 0, mismatches.count < 3 {
            mismatches.append("frame \(frameIndex), top \(frame.top): \(differing) bytes differ")
        }
        checked += 1
    }
    #expect(checked > 10)
    #expect(mismatches.isEmpty, "\(mismatches.joined(separator: "\n"))")
}
