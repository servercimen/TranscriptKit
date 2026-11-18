import CoreGraphics
import CoreText
import Foundation

/// The custom tags of a block that take padding or draw shapes, and what
/// layout needs to know about them. Nil for a block without any, which is
/// most blocks.
struct DecoratedTags {
    struct Tag {
        let range: Range<Int>
        /// Where its text ends, not counting line breaks at its end.
        let textEnd: Int
        let tag: InlineSpan.CustomTag
        /// Its place among the block's spans, where outer tags come first.
        let order: Int

        var padding: CGFloat { tag.decoration.padding }
    }

    /// Outer tags first.
    let tags: [Tag]
    /// Extra advance after a character, by its offset: a tag's padding
    /// before it goes on the character before the tag (unless that is a
    /// line break), and its padding after it on its last character. Kept
    /// even while the tag is open, so its end acts like a wider last glyph:
    /// only the word being written can wrap because of it.
    let kerns: [Int: CGFloat]
    /// The padding of the tags that start at an offset, added up: a line
    /// that starts there is moved right by it, since there is no character
    /// before it on the line to carry it.
    let startPadding: [Int: CGFloat]

    /// Whether any of the block's tags take padding or draw shapes.
    static func appear(in block: TranscriptBlock) -> Bool {
        block.spans.contains { $0.customTag?.decoration.shapesText == true }
    }

    /// - Parameter start: only tags that reach this offset or past it are
    ///   kept: a streaming update lays out only the lines from there on.
    init?(_ block: TranscriptBlock, from start: Int = 0) {
        guard Self.appear(in: block) else { return nil }
        let text = block.text as NSString
        var tags: [Tag] = []
        var kerns: [Int: CGFloat] = [:]
        var startPadding: [Int: CGFloat] = [:]
        for (order, span) in block.spans.enumerated() where span.range.upperBound >= start {
            guard let custom = span.customTag, custom.decoration.shapesText else { continue }
            var textEnd = span.range.upperBound
            while textEnd > span.range.lowerBound, text.character(at: textEnd - 1) == 0x0A { textEnd -= 1 }
            let tag = Tag(range: span.range, textEnd: textEnd, tag: custom, order: order)
            tags.append(tag)
            guard tag.padding > 0 else { continue }
            let before = span.range.lowerBound - 1
            if before >= 0, text.character(at: before) != 0x0A { kerns[before, default: 0] += tag.padding }
            if textEnd > span.range.lowerBound { kerns[textEnd - 1, default: 0] += tag.padding }
            startPadding[span.range.lowerBound, default: 0] += tag.padding
        }
        self.tags = tags
        self.kerns = kerns
        self.startPadding = startPadding
    }

    /// Whether `inner` is `outer` or inside it.
    private func isWithin(_ inner: Tag, _ outer: Tag) -> Bool {
        outer.range.lowerBound <= inner.range.lowerBound && inner.range.upperBound <= outer.range.upperBound
            && (inner.range != outer.range || inner.order >= outer.order)
    }

    /// The padding a tag's box has at its start: its own and that of the
    /// tags inside it that start with it.
    func startPadding(of tag: Tag) -> CGFloat {
        tags.reduce(0) { $0 + ($1.range.lowerBound == tag.range.lowerBound && isWithin($1, tag) ? $1.padding : 0) }
    }

    /// The same at its end.
    func endPadding(of tag: Tag) -> CGFloat {
        tags.reduce(0) { $0 + ($1.textEnd == tag.textEnd && isWithin($1, tag) ? $1.padding : 0) }
    }
}

/// The shapes custom tags draw on one line, made when it is laid out, in the
/// line's coordinates (x from where its glyphs start, y down from its baseline).
final class LineDecorations: @unchecked Sendable {
    let behind: [TranscriptPath]
    let over: [TranscriptPath]
    /// How far the shapes reach above the line's top and below its bottom,
    /// at most `TranscriptPath.maximumOverhang`. Drawing is clipped to it.
    let inkAbove: CGFloat
    let inkBelow: CGFloat
    /// Linked tags with padding, by their box: a tap on the padding belongs
    /// to the tag, not to the character the spacing was added to.
    let links: [(rect: CGRect, link: String)]

    private init(behind: [TranscriptPath], over: [TranscriptPath], inkAbove: CGFloat, inkBelow: CGFloat,
                 links: [(rect: CGRect, link: String)]) {
        self.behind = behind
        self.over = over
        self.inkAbove = inkAbove
        self.inkBelow = inkBelow
        self.links = links
    }

    /// - Parameters:
    ///   - visibleWidth: the line's width without trailing whitespace; a tag
    ///     that goes on to the next line ends here.
    ///   - top, bottom: the line box, down from the baseline.
    ///   - text: the attributed string the line was typeset from, which
    ///     starts at block offset `textBase`.
    ///   - lineX: where the line starts in the block, and `blockWidth` the
    ///     block's width: what is visible depends on them.
    static func make(line: CTLine, range: Range<Int>, indexBase: Int, visibleWidth: CGFloat, top: CGFloat, bottom: CGFloat,
                     lineX: CGFloat, blockWidth: CGFloat,
                     tags: DecoratedTags, text: NSAttributedString, textBase: Int) -> LineDecorations? {
        guard !range.isEmpty,
              tags.tags.contains(where: { $0.range.lowerBound < range.upperBound && $0.textEnd > range.lowerBound }) else { return nil }
        let glyphs = GlyphTable(line)
        let side = TranscriptPath.maximumSideOverhang
        let cap = TranscriptPath.maximumOverhang
        let visible = CGRect(x: -lineX - side, y: top - cap, width: blockWidth + 2 * side, height: bottom - top + 2 * cap)
        var behind: [TranscriptPath] = []
        var over: [TranscriptPath] = []
        var links: [(rect: CGRect, link: String)] = []
        var inkTop = top
        var inkBottom = bottom
        for tag in tags.tags where tag.range.lowerBound < range.upperBound && tag.textEnd > range.lowerBound {
            let start = max(tag.range.lowerBound, range.lowerBound)
            let end = min(tag.textEnd, range.upperBound)
            guard end > start, start - textBase >= 0, start - textBase < text.length else { continue }
            let isStart = tag.range.lowerBound >= range.lowerBound
            let isEnd = tag.textEnd <= range.upperBound
            // From the glyphs: Core Text puts the caret halfway through
            // spacing added after a character, which is where padding is.
            let minX = glyphs.start(at: start - indexBase) ?? CTLineGetOffsetForStringIndex(line, start - indexBase, nil)
            // At the tag's end, the spacing after its last character is padding, not text.
            let maxX = isEnd
                ? (glyphs.end(through: end - 1 - indexBase) ?? CTLineGetOffsetForStringIndex(line, end - indexBase, nil))
                    - (tags.kerns[end - 1] ?? 0)
                : visibleWidth
            guard maxX > minX else { continue }
            // The tag's own font, which a fallback font for an emoji doesn't change.
            let font = text.attribute(TranscriptStyle.fontKey, at: start - textBase, effectiveRange: nil).map { $0 as! CTFont }
                ?? CTFontCreateUIFontForLanguage(.system, 17, nil)!
            let ascent = CTFontGetAscent(font)
            let descent = CTFontGetDescent(font)
            let textRect = CGRect(x: minX, y: -ascent, width: maxX - minX, height: ascent + descent)
            let left = minX - (isStart ? tags.startPadding(of: tag) : 0)
            let right = maxX + (isEnd ? tags.endPadding(of: tag) : 0)
            let rect = CGRect(x: left, y: -ascent, width: right - left, height: ascent + descent)
            let fragment = TranscriptFragment(
                textRect: textRect, rect: rect, isStart: isStart, isEnd: isEnd,
                ascent: ascent, descent: descent, xHeight: CTFontGetXHeight(font), capHeight: CTFontGetCapHeight(font),
                underlineOffset: -CTFontGetUnderlinePosition(font), underlineThickness: CTFontGetUnderlineThickness(font),
                seed: stableHash(tag.tag.name, tag.range.lowerBound, start),
                visibleRect: visible
            )
            for shape in tag.tag.decoration.shapes {
                for path in shape.paths(for: fragment) {
                    let ink = path.inkBounds
                    guard !ink.isNull else { continue }
                    inkTop = min(inkTop, ink.minY)
                    inkBottom = max(inkBottom, ink.maxY)
                    if path.layer == .behindText { behind.append(path) } else { over.append(path) }
                }
            }
            if let link = tag.tag.decoration.link, tag.padding > 0 {
                links.append((rect, link))
            }
        }
        guard !behind.isEmpty || !over.isEmpty || !links.isEmpty else { return nil }
        return LineDecorations(behind: behind, over: over, inkAbove: min(max(top - inkTop, 0), cap),
                               inkBelow: min(max(inkBottom - bottom, 0), cap), links: links)
    }
}

/// A line's glyphs by string index, read from Core Text once.
private struct GlyphTable {
    private var indices: [CFIndex] = []
    private var positions: [CGFloat] = []
    private var advances: [CGFloat] = []

    init(_ line: CTLine) {
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var runIndices = [CFIndex](repeating: 0, count: count)
            var runPositions = [CGPoint](repeating: .zero, count: count)
            var runAdvances = [CGSize](repeating: .zero, count: count)
            CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &runIndices)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &runPositions)
            CTRunGetAdvances(run, CFRange(location: 0, length: 0), &runAdvances)
            indices += runIndices
            positions += runPositions.map(\.x)
            advances += runAdvances.map(\.width)
        }
    }

    /// The left edge of the first glyph for string index `index` or later.
    func start(at index: Int) -> CGFloat? {
        var best: (index: Int, x: CGFloat)?
        for glyph in indices.indices where indices[glyph] >= index {
            if best == nil || indices[glyph] < best!.index { best = (indices[glyph], positions[glyph]) }
        }
        return best?.x
    }

    /// The right edge of the last glyph for string index `index` or earlier:
    /// its position plus its advance, which includes spacing added after it.
    func end(through index: Int) -> CGFloat? {
        var best: (index: Int, x: CGFloat)?
        for glyph in indices.indices where indices[glyph] <= index {
            if best == nil || indices[glyph] >= best!.index { best = (indices[glyph], positions[glyph] + advances[glyph]) }
        }
        return best?.x
    }
}
