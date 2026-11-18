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
        block.spans.contains { $0.customTag?.shapesText == true }
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
            guard let custom = span.customTag, custom.shapesText else { continue }
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

/// One occurrence of a custom tag in a document: its block, where its text
/// starts there, and its name. The same from one update to the next.
struct TagKey: Hashable, Sendable {
    let block: String
    let start: Int
    let name: String
}

/// Animated tags that drawing leaves out, in part or whole.
struct TagHiding: Equatable, Sendable {
    /// Playing their animations, which draw them: glyphs and shapes are left out.
    var playing: Set<TagKey> = []
    /// Waiting to play: shown as text, so their shapes are left out.
    var waiting: Set<TagKey> = []

    static let none = TagHiding()

    var isEmpty: Bool { playing.isEmpty && waiting.isEmpty }

    func hidesShapes(of key: TagKey) -> Bool {
        playing.contains(key) || waiting.contains(key)
    }
}

/// A glyph of a line, found again: run `run`, glyph `index` in it.
struct GlyphSource: @unchecked Sendable {
    let run: CTRun
    let index: CFIndex
}

/// One line's part of an animated tag that has closed: what its animation
/// needs, and what drawing leaves out while it plays.
struct AnimatedFragment: Sendable {
    let key: TagKey
    let animation: TranscriptDecoration.Animation
    let fragment: TranscriptFragment
    /// The tag's text on this line, in block offsets.
    let range: Range<Int>
    /// Where each of `fragment.glyphs` is in the line, to draw it alone.
    let sources: [GlyphSource]
}

/// The shapes custom tags draw on one line, made when it is laid out, in the
/// line's coordinates (x from where its glyphs start, y down from its baseline).
final class LineDecorations: @unchecked Sendable {
    let behind: [TranscriptPath]
    let over: [TranscriptPath]
    /// For each of `behind` and `over`, the animated tag it belongs to, if
    /// any: the path is left out while that tag's animation plays. Empty on
    /// a line without an animated tag.
    let behindTags: [TagKey?]
    let overTags: [TagKey?]
    /// The animated tags on the line that have closed.
    let animated: [AnimatedFragment]
    /// How far the shapes reach above the line's top and below its bottom,
    /// at most `TranscriptPath.maximumOverhang`. Drawing is clipped to it.
    let inkAbove: CGFloat
    let inkBelow: CGFloat
    /// Linked tags with padding, by their box: a tap on the padding belongs
    /// to the tag, not to the character the spacing was added to.
    let links: [(rect: CGRect, link: String)]

    private init(behind: [TranscriptPath], over: [TranscriptPath], behindTags: [TagKey?], overTags: [TagKey?],
                 animated: [AnimatedFragment], inkAbove: CGFloat, inkBelow: CGFloat, links: [(rect: CGRect, link: String)]) {
        self.behind = behind
        self.over = over
        self.behindTags = behindTags
        self.overTags = overTags
        self.animated = animated
        self.inkAbove = inkAbove
        self.inkBelow = inkBelow
        self.links = links
    }

    /// The text of the tags in `hidden` on this line, in block offsets.
    func hiddenRanges(_ hidden: Set<TagKey>) -> [Range<Int>] {
        guard !hidden.isEmpty, !animated.isEmpty else { return [] }
        return animated.compactMap { hidden.contains($0.key) ? $0.range : nil }
    }

    /// - Parameters:
    ///   - visibleWidth: the line's width without trailing whitespace; a tag
    ///     that goes on to the next line ends here.
    ///   - top, bottom: the line box, down from the baseline.
    ///   - text: the attributed string the line was typeset from, which
    ///     starts at block offset `textBase`.
    ///   - lineX: where the line starts in the block, and `blockWidth` the
    ///     block's width: what is visible depends on them.
    ///   - block: the block's id, which names its animated tags.
    static func make(line: CTLine, range: Range<Int>, indexBase: Int, visibleWidth: CGFloat, top: CGFloat, bottom: CGFloat,
                     lineX: CGFloat, blockWidth: CGFloat, block: String,
                     tags: DecoratedTags, text: NSAttributedString, textBase: Int) -> LineDecorations? {
        guard !range.isEmpty,
              tags.tags.contains(where: { $0.range.lowerBound < range.upperBound && $0.textEnd > range.lowerBound }) else { return nil }
        let glyphs = GlyphTable(line)
        let side = TranscriptPath.maximumSideOverhang
        let cap = TranscriptPath.maximumOverhang
        let visible = CGRect(x: -lineX - side, y: top - cap, width: blockWidth + 2 * side, height: bottom - top + 2 * cap)
        var behind: [TranscriptPath] = []
        var over: [TranscriptPath] = []
        // Which paths belong to animated tags, by index; most lines have none.
        var keyed: [(over: Bool, index: Int, key: TagKey)] = []
        var animated: [AnimatedFragment] = []
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
            // An animated tag shows its shapes once it has closed, when its
            // animation brings them in; until then it is plain text.
            let animation = tag.tag.isAnimated ? tag.tag.decoration.animation : nil
            let key = animation == nil ? nil : TagKey(block: block, start: tag.range.lowerBound, name: tag.tag.name)
            var glyphBoxes: [TranscriptGlyph] = []
            var sources: [GlyphSource] = []
            if animation != nil, !tag.tag.isOpen {
                for glyph in glyphs.glyphs(in: (start - indexBase)..<(end - indexBase)) {
                    glyphBoxes.append(TranscriptGlyph(bounds: glyph.bounds, index: glyph.stringIndex + indexBase - tag.range.lowerBound))
                    sources.append(glyph.source)
                }
            }
            let fragment = TranscriptFragment(
                textRect: textRect, rect: rect, isStart: isStart, isEnd: isEnd,
                ascent: ascent, descent: descent, xHeight: CTFontGetXHeight(font), capHeight: CTFontGetCapHeight(font),
                underlineOffset: -CTFontGetUnderlinePosition(font), underlineThickness: CTFontGetUnderlineThickness(font),
                seed: stableHash(tag.tag.name, tag.range.lowerBound, start),
                visibleRect: visible, glyphs: glyphBoxes
            )
            let showsShapes = animation == nil || !tag.tag.isOpen
            if let animation, let key, showsShapes {
                animated.append(AnimatedFragment(key: key, animation: animation, fragment: fragment, range: start..<end, sources: sources))
            }
            for shape in tag.tag.decoration.shapes where showsShapes {
                for path in shape.paths(for: fragment) {
                    let ink = path.inkBounds
                    guard !ink.isNull else { continue }
                    inkTop = min(inkTop, ink.minY)
                    inkBottom = max(inkBottom, ink.maxY)
                    let isOver = path.layer == .overText
                    if let key { keyed.append((isOver, isOver ? over.count : behind.count, key)) }
                    if isOver { over.append(path) } else { behind.append(path) }
                }
            }
            if let link = tag.tag.decoration.link, tag.padding > 0 {
                links.append((rect, link))
            }
        }
        guard !behind.isEmpty || !over.isEmpty || !links.isEmpty || !animated.isEmpty else { return nil }
        var behindTags: [TagKey?] = []
        var overTags: [TagKey?] = []
        if !keyed.isEmpty {
            behindTags = Array(repeating: nil, count: behind.count)
            overTags = Array(repeating: nil, count: over.count)
            for (isOver, index, key) in keyed {
                if isOver { overTags[index] = key } else { behindTags[index] = key }
            }
        }
        return LineDecorations(behind: behind, over: over, behindTags: behindTags, overTags: overTags, animated: animated,
                               inkAbove: min(max(top - inkTop, 0), cap), inkBelow: min(max(inkBottom - bottom, 0), cap), links: links)
    }
}

/// A line's glyphs by string index, read from Core Text once.
private struct GlyphTable {
    private let runs: [CTRun]
    private var indices: [CFIndex] = []
    private var positions: [CGFloat] = []
    private var advances: [CGFloat] = []
    /// Where each run's glyphs start in the arrays above.
    private var runStarts: [Int] = []

    init(_ line: CTLine) {
        runs = CTLineGetGlyphRuns(line) as! [CTRun]
        for (runIndex, run) in runs.enumerated() {
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
            while runStarts.count < runIndex { runStarts.append(indices.count - count) }
            runStarts.append(indices.count - count)
        }
    }

    /// The glyphs for the characters in `range` (the line's string
    /// indexes), in string order, with their typographic boxes. Images,
    /// which are drawn on their own, are left out.
    func glyphs(in range: Range<Int>) -> [(bounds: CGRect, stringIndex: Int, source: GlyphSource)] {
        var found: [(bounds: CGRect, stringIndex: Int, source: GlyphSource)] = []
        for glyph in indices.indices where range.contains(indices[glyph]) {
            // The last run starting at or before this glyph.
            var runIndex = runStarts.count - 1
            while runIndex > 0, runStarts[runIndex] > glyph { runIndex -= 1 }
            let run = runs[runIndex]
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard attributes[TranscriptStyle.imageKey.rawValue] == nil,
                  let font = attributes[kCTFontAttributeName].map({ $0 as! CTFont }) else { continue }
            let ascent = CTFontGetAscent(font)
            let bounds = CGRect(x: positions[glyph], y: -ascent, width: advances[glyph], height: ascent + CTFontGetDescent(font))
            found.append((bounds, indices[glyph], GlyphSource(run: run, index: glyph - runStarts[runIndex])))
        }
        return found.sorted { $0.stringIndex < $1.stringIndex }
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
