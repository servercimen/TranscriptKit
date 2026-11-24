import CoreGraphics
import Testing
@testable import TranscriptKit

@Test func aShortTextGetsASmallTile() {
    #expect(TileGrid.tileHeight(at: 0, viewHeight: 20) == 32)
    #expect(TileGrid.tileHeight(at: 0, viewHeight: 26) == 32)
    #expect(TileGrid.tileHeight(at: 0, viewHeight: 27) == 64)
    #expect(TileGrid.tileHeight(at: 0, viewHeight: 100) == 128)
    #expect(TileGrid.tileHeight(at: 0, viewHeight: 200) == 256)
}

@Test func aTallerTextKeepsFullTiles() {
    for viewHeight: CGFloat in [251, 300, 600, 1000] {
        let count = Int((viewHeight / TileGrid.height).rounded(.up))
        for index in 0..<count {
            #expect(TileGrid.tileHeight(at: index, viewHeight: viewHeight) == TileGrid.height)
        }
    }
}

@Test func aShortTextsTileCoversItAndTheShapesBelowIt() {
    for height in stride(from: CGFloat(1), through: 300, by: 0.5) {
        let tile = TileGrid.tileHeight(at: 0, viewHeight: height)
        let needed = height + TranscriptPath.maximumOverhang
        #expect(tile >= min(needed, TileGrid.height))
        #expect(tile == TileGrid.minimumHeight || tile == TileGrid.height || tile / 2 < needed)
    }
}

@Test func growingTextResizesItsTileAtMostThreeTimes() {
    var heights: [CGFloat] = []
    for height in stride(from: CGFloat(1), through: 2 * TileGrid.height, by: 1) {
        let tile = TileGrid.tileHeight(at: 0, viewHeight: height)
        if heights.last != tile { heights.append(tile) }
    }
    #expect(heights == [32, 64, 128, 256])
}

@Test func aShortTextsTileCoversGlyphsThatDrawBelowIt() {
    #expect(TileGrid.tileHeight(at: 0, viewHeight: 21, glyphBottom: 20) == 32)
    #expect(TileGrid.tileHeight(at: 0, viewHeight: 21, glyphBottom: 35) == 64)
    #expect(TileGrid.tileHeight(at: 0, viewHeight: 21, glyphBottom: 300) == TileGrid.height)
}

@Test func stackedMarksDrawBelowTheLayout() {
    let marks = String(repeating: "\u{323}", count: 5)
    let stacked = DocumentLayout(document: TranscriptDocument(blocks: [TranscriptBlock(id: "a", text: "a\(marks) b")]), width: 300)
    #expect(stacked.glyphBottom > stacked.height + TranscriptPath.maximumOverhang)

    let plain = DocumentLayout(document: TranscriptDocument(blocks: [TranscriptBlock(id: "a", text: "Descenders: gjpqy")]), width: 300)
    #expect(plain.glyphBottom > 0)
    #expect(plain.glyphBottom <= plain.height)
}

@Test func aTallLayoutDoesNotMeasureItsGlyphs() {
    let text = String(repeating: "A paragraph that fills more than one tile. ", count: 60)
    let layout = DocumentLayout(document: TranscriptDocument(blocks: [TranscriptBlock(id: "a", text: text)]), width: 300)
    #expect(layout.height >= TileGrid.height)
    #expect(layout.glyphBottom == layout.height)
}

@Test func theFirstTileStartsAboveTheView() {
    let overhang = TranscriptPath.maximumOverhang
    for viewHeight: CGFloat in [1, 20, 26, 27, 100, 250, 300, 600] {
        let first = TileGrid.tileFrame(at: 0, viewHeight: viewHeight)
        #expect(first.top == -overhang)
        // Its bottom stays where it was, under the view and the shapes below it.
        #expect(first.top + first.height == TileGrid.tileHeight(at: 0, viewHeight: viewHeight))
    }
    let second = TileGrid.tileFrame(at: 1, viewHeight: 600)
    #expect(second.top == TileGrid.height && second.height == TileGrid.height)
    // Glyphs that draw below the text are still covered.
    let marked = TileGrid.tileFrame(at: 0, viewHeight: 21, glyphBottom: 35)
    #expect(marked.top + marked.height >= 35)
}

/// A pill with room above the text, on the first line of a view without
/// padding, reaches above the view: the first tile and the tail draw it.
@Test func aPillAboveTheFirstLineIsDrawn() throws {
    let red = TranscriptColor(red: 1, green: 0, blue: 0)
    let tag = TranscriptTag("pill", TranscriptDecoration(padding: 4, shapes: [.pill(fill: red, verticalPadding: 4)]))
    let document = MarkdownStreamParser.document(from: "<pill>Pill</pill> on the first line", idPrefix: "p", tags: [tag])
    let layout = DocumentLayout(document: document, width: 300)
    let line = layout.entry(at: 0).layout.lines[0]
    #expect(layout.entry(at: 0).y + line.inkTop < -2)
    #expect(TailRenderer.lastLineTop(of: layout, scale: 2) < -2)
    #expect(TailRenderer.lastLineTop(of: layout, scale: 2) >= -TranscriptPath.maximumOverhang)

    // Drawn into the first tile's rows, the pill shows above y = 0.
    let scale: CGFloat = 2
    let tile = TileGrid.tileFrame(at: 0, viewHeight: layout.height)
    let width = Int((layout.width * scale).rounded())
    let height = Int((tile.height * scale).rounded())
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: scale, y: -scale)
    context.translateBy(x: 0, y: -tile.top)
    let rows = CGRect(x: 0, y: tile.top, width: layout.width, height: tile.height)
    layout.draw(in: context, dirtyRect: rows, text: CGColor(gray: 0, alpha: 1), codeBackground: CGColor(gray: 0.9, alpha: 1),
                accent: CGColor(gray: 0.6, alpha: 1))
    let bytes = UnsafeRawBufferPointer(start: context.data!, count: width * height * 4)
    // One point above the view, in the middle of the pill.
    let x = Int(((line.frame.minX + 12) * scale).rounded())
    let y = Int(((-1 - tile.top) * scale).rounded())
    #expect(bytes[(y * width + x) * 4] > 200)
}
