import CoreGraphics
import Foundation
import Testing
@testable import TranscriptKit

private let hebrew = String(repeating: "שלום עולם, זה משפט ארוך בעברית. ", count: 5)

private func layout(_ markdown: String, width: CGFloat = 300) -> DocumentLayout {
    DocumentLayout(document: MarkdownStreamParser.document(from: markdown), width: width)
}

// MARK: Selection and hit testing

@Test func directionIsFoundByOffset() {
    let document = layout("Hello world\n\nمرحبا بالعالم")
    let start = document.entry(at: 1).start
    #expect(document.isRightToLeft(at: start))
    #expect(!document.isRightToLeft(at: start, backward: true))
    #expect(document.isRightToLeft(at: start + 1, backward: true))
    #expect(!document.isRightToLeft(at: 0))
}

@Test func caretsHitTestBackInRightToLeftText() {
    let document = layout(hebrew)
    for offset in stride(from: 0, to: document.length, by: 5) {
        let rect = document.caretRect(at: offset)
        let hit = document.closestOffset(to: CGPoint(x: rect.midX, y: rect.midY))
        #expect(abs(hit - offset) <= 1, "offset \(offset) hit-tested to \(hit)")
    }
    // Right of a line is its start; left of it is its end.
    let line = document.entry(at: 0).layout.lines[0]
    #expect(document.closestOffset(to: CGPoint(x: 299, y: line.frame.midY)) == 0)
    #expect(document.closestOffset(to: CGPoint(x: 1, y: line.frame.midY)) == line.range.upperBound - 1)
}

@Test func rightToLeftSelectionStartsOnTheRight() {
    let document = layout(hebrew)
    let line = document.entry(at: 0).layout.lines[0]
    let segments = document.selectionSegments(for: 0..<4)
    #expect(segments.count == 1)
    #expect(segments[0].isRightToLeft)
    #expect(abs(segments[0].rect.maxX - line.frame.maxX) < 0.5)
    #expect(segments[0].containsStart && segments[0].containsEnd)

    let all = document.selectionSegments(for: 0..<document.length)
    #expect(all.count == document.entry(at: 0).layout.lines.count)
    for (segment, line) in zip(all, document.entry(at: 0).layout.lines) {
        #expect(abs(segment.rect.minX - line.frame.minX) < 0.5)
        #expect(abs(segment.rect.maxX - line.frame.maxX) < 0.5)
    }
    #expect(all.first!.containsStart && !all.first!.containsEnd)
    #expect(all.last!.containsEnd && !all.last!.containsStart)
}

@Test func mixedDirectionSelectionHasARectForEachRun() {
    let text = "Say שלום עולם to all"
    let document = layout(text, width: 400)
    let line = document.entry(at: 0).layout.lines[0]
    // "y שלום" : the end of an English word, then the start of a Hebrew one.
    let range = 2..<8
    let segments = document.selectionSegments(for: range)
    #expect(segments.count == 2)
    #expect(segments.map(\.isRightToLeft) == [false, true])
    #expect(segments[0].rect.maxX <= segments[1].rect.minX + 0.5)
    #expect(segments.allSatisfy { $0.rect.minX >= line.frame.minX && $0.rect.maxX <= line.frame.maxX + 0.5 })
    // The first Hebrew word is drawn at the right of the Hebrew, so the
    // second word lies between the two rects.
    #expect(abs(segments[1].rect.minX - document.caretRect(at: 8).midX) < 1)
    #expect(segments[1].rect.minX - segments[0].rect.maxX > 10)
    #expect(segments[0].containsStart && segments[1].containsEnd)
    #expect(document.selectionRects(for: range) == segments.map(\.rect))
}

@Test func leftToRightSelectionIsOneRectPerLine() {
    let document = layout(String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 4))
    let segments = document.selectionSegments(for: 3..<document.length)
    #expect(segments.count == document.entry(at: 0).layout.lines.count)
    #expect(segments.allSatisfy { !$0.isRightToLeft })
    #expect(segments.map(\.containsStart) == [true] + Array(repeating: false, count: segments.count - 1))
    #expect(segments.map(\.containsEnd) == Array(repeating: false, count: segments.count - 1) + [true])
}

@Test func linkInRightToLeftTextIsFoundUnderItsGlyphs() {
    let document = layout("שלום [עולם](https://example.com) וכולם")
    let block = document.entry(at: 0).layout
    let linkStart = 5
    for offset in linkStart..<(linkStart + 4) {
        let a = block.caretRect(atOffset: offset).midX
        let b = block.caretRect(atOffset: offset + 1).midX
        let point = CGPoint(x: (a + b) / 2, y: block.lines[0].frame.midY)
        #expect(block.characterOffset(at: point) == offset)
        #expect(document.link(at: point) == "https://example.com")
    }
    let before = (block.caretRect(atOffset: 2).midX + block.caretRect(atOffset: 3).midX) / 2
    #expect(document.link(at: CGPoint(x: before, y: block.lines[0].frame.midY)) == nil)
}
