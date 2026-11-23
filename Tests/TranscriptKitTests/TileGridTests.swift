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
