import CoreGraphics
import CoreText
import Foundation

/// Text that arrived in one update and fades in from then on.
struct Fade: Sendable {
    let id: Int
    /// Flat offsets.
    let range: Range<Int>
    /// When it started, in `CACurrentMediaTime()`.
    let start: CFTimeInterval
}

/// The text that is fading in, drawn on the layout queue for the view's fade
/// layers: one piece for each fade on each line, with only that fade's
/// glyphs on it.
struct FadeFrame: @unchecked Sendable {
    struct Piece: @unchecked Sendable {
        let fade: Int
        let start: CFTimeInterval
        /// Where it goes, in document points, on whole pixels.
        let frame: CGRect
        /// The same object as in the last frame while the piece is unchanged,
        /// so the view gives Core Animation a new image only when it is new.
        let image: CGImage
    }

    let pieces: [Piece]
    let scale: CGFloat
}

/// Draws the pieces of the text that fades in. A piece is drawn once and
/// kept while its glyphs stay where they are; the text that fades is laid
/// out again with every update, so a word that wraps or a centered line
/// that moves gets its pieces drawn again.
///
/// Not thread-safe: use it from one queue (the layout engine's).
final class FadeRenderer {
    private struct Placement: Equatable {
        let range: Range<Int>
        let frame: CGRect
        let origin: CGPoint
        let style: Style
    }

    /// What the text's look comes from: text whose style changed in place
    /// (code colors arrived, a reference became a link) is drawn again.
    private struct Style: Equatable {
        let spans: [InlineSpan]
        let imageRevision: Int?
        let definitions: Int
    }

    private struct Drawn {
        let placement: Placement
        let image: CGImage
    }

    /// The pieces drawn last, by fade.
    private var drawn: [Int: [Drawn]] = [:]
    private var colors: TailRenderer.Colors?
    private var scale: CGFloat = 0

    /// How far a line's glyphs may reach beyond its box: accents, descenders,
    /// emoji, italic overhangs.
    static func margin(of line: BlockLayout.Line) -> (x: CGFloat, y: CGFloat) {
        (8, max(line.frame.height, 8))
    }

    /// - Parameter from: where the text left out of the tail and the tiles
    ///   starts; the oldest fade may start before it.
    func render(_ layout: DocumentLayout, from: Int, fades: [Fade], colors: TailRenderer.Colors, scale: CGFloat,
                playing: Set<TagKey>) -> FadeFrame? {
        if scale != self.scale || self.colors.map({ $0.text != colors.text || $0.dark != colors.dark }) ?? true {
            drawn.removeAll()
            self.colors = colors
            self.scale = scale
        }
        let live = Set(fades.map(\.id))
        drawn = drawn.filter { live.contains($0.key) }
        guard !fades.isEmpty, from < layout.length, scale > 0 else { return nil }
        func pixel(_ value: CGFloat, _ rule: FloatingPointRoundingRule) -> CGFloat { (value * scale).rounded(rule) / scale }

        let lines = layout.lines(from: from)
        let rightToLeft = lines.map { $0.line.hasRightToLeftRuns }
        let definitions = layout.document.linkDefinitions.count
        var pieces: [FadeFrame.Piece] = []
        for fade in fades {
            let previous = drawn[fade.id] ?? []
            var current: [Drawn] = []
            for (index, (entry, line)) in lines.enumerated() {
                let lineStart = entry.start + line.range.lowerBound
                let lineEnd = entry.start + line.range.upperBound
                let lower = max(fade.range.lowerBound, lineStart, from)
                let upper = min(fade.range.upperBound, lineEnd)
                guard lower < upper else { continue }
                let range = lower..<upper
                let margin = Self.margin(of: line)
                let origin = CGPoint(x: line.frame.minX, y: entry.y + line.baseline)
                var minX = line.frame.minX
                var maxX = line.frame.maxX
                if !rightToLeft[index] {
                    let carets = [range.lowerBound, range.upperBound].map {
                        origin.x + CTLineGetOffsetForStringIndex(line.ctLine, $0 - entry.start - line.indexBase, nil)
                    }
                    minX = carets.min()!
                    maxX = carets.max()!
                }
                let frame = CGRect(x: pixel(minX - margin.x, .down), y: pixel(entry.y + line.frame.minY - margin.y, .down),
                                   width: 0, height: 0)
                let placement = Placement(
                    range: range,
                    frame: CGRect(x: frame.minX, y: frame.minY, width: pixel(maxX + margin.x, .up) - frame.minX,
                                  height: pixel(entry.y + line.frame.maxY + margin.y, .up) - frame.minY),
                    origin: origin,
                    style: Style(spans: entry.layout.block.spans.filter {
                        $0.range.lowerBound < range.upperBound - entry.start && $0.range.upperBound > range.lowerBound - entry.start
                    }, imageRevision: entry.layout.imageRevision, definitions: definitions))
                let image: CGImage
                if current.count < previous.count, previous[current.count].placement == placement {
                    image = previous[current.count].image
                } else {
                    var hidden = line.decorations?.hiddenRanges(playing) ?? []
                    let local = (range.lowerBound - entry.start)..<(range.upperBound - entry.start)
                    if local.lowerBound > line.range.lowerBound { hidden.append(line.range.lowerBound..<local.lowerBound) }
                    if local.upperBound < line.range.upperBound { hidden.append(local.upperBound..<line.range.upperBound) }
                    guard let drawnImage = Self.draw(line, at: origin, in: placement.frame, hiding: hidden, colors: colors, scale: scale)
                    else { continue }
                    image = drawnImage
                }
                current.append(Drawn(placement: placement, image: image))
                pieces.append(.init(fade: fade.id, start: fade.start, frame: placement.frame, image: image))
            }
            drawn[fade.id] = current
        }
        return FadeFrame(pieces: pieces, scale: scale)
    }

    /// `line`'s glyphs, leaving out `hidden` (block offsets), in a bitmap of `frame`.
    private static func draw(_ line: BlockLayout.Line, at origin: CGPoint, in frame: CGRect, hiding hidden: [Range<Int>],
                             colors: TailRenderer.Colors, scale: CGFloat) -> CGImage? {
        let width = Int((frame.width * scale).rounded())
        let height = Int((frame.height * scale).rounded())
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        // Top-left origin, in document points.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -frame.minX, y: -frame.minY)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        DocumentLayout.drawGlyphs(of: line.ctLine, at: origin,
                                  hidden: hidden.map { ($0.lowerBound - line.indexBase)..<($0.upperBound - line.indexBase) },
                                  in: context, text: colors.text, dark: colors.dark)
        return context.makeImage()
    }
}
