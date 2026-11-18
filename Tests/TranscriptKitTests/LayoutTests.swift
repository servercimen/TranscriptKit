import CoreGraphics
import Testing
@testable import TranscriptKit

private func sampleDocument() -> TranscriptDocument {
    TranscriptDocument(blocks: [
        TranscriptBlock(id: "h", kind: .heading(level: 1), text: "Title"),
        TranscriptBlock(id: "p", text: String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 6)),
        TranscriptBlock(id: "c", kind: .code(), text: "let a = 1\nlet b = 2"),
    ])
}

@Test func flatTextJoinsBlocksWithNewlines() {
    let document = TranscriptDocument(blocks: [
        TranscriptBlock(id: "a", text: "Hello"),
        TranscriptBlock(id: "b", text: "World"),
    ])
    #expect(document.utf16Count == 11)
    #expect(document.text(in: 0..<11) == "Hello\nWorld")
    #expect(document.text(in: 3..<8) == "lo\nWo")
    #expect(document.text(in: 5..<6) == "\n")
    #expect(document.text(in: 6..<6) == "")
}

@Test func paragraphWrapsIntoSeveralLines() {
    let layout = DocumentLayout(document: sampleDocument(), width: 300)
    #expect(layout.entry(at: 1).layout.lines.count > 2)
    #expect(layout.length == sampleDocument().utf16Count)
    #expect(layout.height > 0)
}

@Test func hitTestingRoundTripsThroughCaretRects() {
    let document = sampleDocument()
    let layout = DocumentLayout(document: document, width: 300)
    // Every 7th offset: the caret's position must hit-test back to that offset.
    for offset in stride(from: 0, to: layout.length, by: 7) {
        // Skip offsets that sit on a line's trailing edge, which hit-test to the line start below.
        let rect = layout.caretRect(at: offset)
        let hit = layout.closestOffset(to: CGPoint(x: rect.midX, y: rect.midY))
        #expect(abs(hit - offset) <= 1, "offset \(offset) hit-tested to \(hit)")
    }
}

@Test func selectionSpansBlocks() {
    let document = sampleDocument()
    let layout = DocumentLayout(document: document, width: 300)
    let rects = layout.selectionRects(for: 0..<layout.length)
    let lineCount = (0..<layout.entryCount).reduce(0) { $0 + layout.entry(at: $1).layout.lines.count }
    #expect(rects.count == lineCount)
    // Rects run top to bottom and reach into the last block.
    #expect(rects.map(\.minY) == rects.map(\.minY).sorted())
    #expect(rects.last!.minY >= layout.entry(at: 2).y)
}

@Test func pointBelowDocumentMapsToEnd() {
    let layout = DocumentLayout(document: sampleDocument(), width: 300)
    #expect(layout.closestOffset(to: CGPoint(x: 10_000, y: 10_000)) == layout.length)
    #expect(layout.closestOffset(to: CGPoint(x: -50, y: -50)) == 0)
}

@Test func streamingAppendReusesEarlierBlocks() {
    var document = sampleDocument()
    let first = DocumentLayout(document: document, width: 300)
    document.appendToLastBlock("\nlet c = 3")
    let second = DocumentLayout(document: document, width: 300, reusing: first)
    #expect(second.reusedBlockCount == 2)
    #expect(second.height > first.height)
    // Earlier blocks keep their positions, so nothing above the tail moves.
    #expect(second.entry(at: 1).y == first.entry(at: 1).y)
}

@Test func emptyAndTrailingNewlineBlocksKeepACaretLine() {
    let document = TranscriptDocument(blocks: [
        TranscriptBlock(id: "e", text: ""),
        TranscriptBlock(id: "n", kind: .code(), text: "x\n"),
    ])
    let layout = DocumentLayout(document: document, width: 200)
    #expect(layout.entry(at: 0).layout.lines.count == 1)
    #expect(layout.entry(at: 1).layout.lines.count == 2)
    #expect(layout.caretRect(at: layout.length).height > 0)
}

@Test func extendsDetectsPureAppends() {
    let base = sampleDocument()
    var appended = base
    appended.appendToLastBlock(" more")
    appended.append(TranscriptBlock(id: "n", text: "new"))
    #expect(appended.extends(base))
    #expect(base.extends(base))
    #expect(!base.extends(appended))

    var edited = TranscriptDocument(blocks: base.blocks.map { block in
        var copy = block
        if copy.id == "p" { copy.text = "changed" }
        return copy
    })
    #expect(!edited.extends(base))
    edited.append(TranscriptBlock(id: "n", text: "new"))
    #expect(!edited.extends(base))
}
