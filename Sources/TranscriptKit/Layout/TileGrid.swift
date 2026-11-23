import CoreGraphics

/// How `TranscriptTextView` cuts its text into the tiles that it draws.
enum TileGrid {
    /// The height of a tile in a view that is taller than one tile.
    static let height: CGFloat = 256

    /// The height of the smallest tile.
    static let minimumHeight: CGFloat = 32

    /// The height of tile `index` in a view `viewHeight` points high. A view
    /// shorter than one tile has one tile that covers only the view and the
    /// shapes that reach below its last line, rounded up to 32, 64, 128 or
    /// 256 points. So a one-line text keeps a small drawing, and text that
    /// grows resizes its tile at most three times. In a taller view, every
    /// tile is 256 points high, so a long answer that streams in does not
    /// resize each new tile as it grows.
    static func tileHeight(at index: Int, viewHeight: CGFloat) -> CGFloat {
        let needed = viewHeight + TranscriptPath.maximumOverhang
        guard index == 0, needed < height else { return height }
        var tile = height
        while tile > minimumHeight, tile / 2 >= needed { tile /= 2 }
        return tile
    }
}
