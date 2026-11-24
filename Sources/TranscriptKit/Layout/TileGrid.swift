import CoreGraphics

/// How `TranscriptTextView` cuts its text into the tiles that it draws.
enum TileGrid {
    /// The height of a tile in a view that is taller than one tile.
    static let height: CGFloat = 256

    /// The height of the smallest tile.
    static let minimumHeight: CGFloat = 32

    /// Where tile `index` starts and how high it is, in the view. The first
    /// tile also covers `TranscriptPath.maximumOverhang` above the view, so
    /// that shapes that reach above the first line, such as a pill on the
    /// first line of a view without padding, are not cut. Its bottom is the
    /// same as without that room.
    static func tileFrame(at index: Int, viewHeight: CGFloat, glyphBottom: CGFloat = 0) -> (top: CGFloat, height: CGFloat) {
        let top = index == 0 ? -TranscriptPath.maximumOverhang : CGFloat(index) * height
        let bottom = CGFloat(index) * height + tileHeight(at: index, viewHeight: viewHeight, glyphBottom: glyphBottom)
        return (top, bottom - top)
    }

    /// The height of tile `index` below its top edge in the grid (0 for the
    /// first tile) in a view `viewHeight` points high, whose glyphs draw
    /// down to `glyphBottom`. A view shorter than one tile has one tile
    /// that covers only the view, the shapes that reach below its last
    /// line and the glyphs, rounded up to 32, 64, 128 or 256 points. So a
    /// one-line text keeps a small drawing, and text that grows resizes its
    /// tile at most three times. In a taller view, every tile is 256 points
    /// high, so a long answer that streams in does not resize each new tile
    /// as it grows.
    static func tileHeight(at index: Int, viewHeight: CGFloat, glyphBottom: CGFloat = 0) -> CGFloat {
        let needed = max(viewHeight + TranscriptPath.maximumOverhang, glyphBottom)
        guard index == 0, needed < height else { return height }
        var tile = height
        while tile > minimumHeight, tile / 2 >= needed { tile /= 2 }
        return tile
    }
}
