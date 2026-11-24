import CoreGraphics
import CoreText
import Foundation

/// Stacked block layouts for a whole document at one width.
///
/// All geometry is in document coordinates (top-left origin) and all offsets
/// are in the document's flat UTF-16 space.
///
/// A layout never changes once made, so it can be built on one thread and
/// used on another.
public final class DocumentLayout: @unchecked Sendable {
    struct Entry {
        let layout: BlockLayout
        let y: CGFloat
        /// Flat offset of the block's first character.
        let start: Int

        var frame: CGRect { CGRect(x: 0, y: y, width: layout.width, height: layout.height) }
        var end: Int { start + layout.length }
    }

    public let width: CGFloat
    public let style: TranscriptStyle
    public let height: CGFloat
    /// Total length of the flat offset space.
    public let length: Int
    /// How many block layouts were carried over from the previous layout.
    public let reusedBlockCount: Int
    /// The lowest point that the glyphs of the text draw. It can be below
    /// `height`: marks stacked under a letter draw past the line's descent.
    /// It is measured only for a layout shorter than one tile (see
    /// `TileGrid`). For a taller layout, it is `height`.
    let glyphBottom: CGFloat

    /// One entry per settled block of `document`. Their positions never
    /// change, so successive layouts share this list and only append to it.
    let settled: SharedList<Entry>
    /// One entry per open block.
    let open: [Entry]
    /// The document this layout was built from.
    let document: TranscriptDocument
    /// The image store's revision when this was laid out.
    let imageRevision: Int

    var entryCount: Int { settled.count + open.count }

    func entry(at index: Int) -> Entry {
        index < settled.count ? settled[index] : open[index - settled.count]
    }

    /// Lays out `document`, reusing unchanged blocks from `previous`.
    ///
    /// While a response streams, only the tail block changes: the settled
    /// blocks' entries are carried over without being looked at or copied,
    /// and the tail block keeps the lines above the one being written.
    public convenience init(document: TranscriptDocument, width: CGFloat, style: TranscriptStyle = .init(), reusing previous: DocumentLayout? = nil) {
        self.init(document: document, width: width, style: style, reusing: previous, images: nil)
    }

    /// - Parameter images: where pictures for the document's images come
    ///   from. Blocks with images are laid out again once theirs arrive.
    init(document: TranscriptDocument, width: CGFloat, style: TranscriptStyle, reusing previous: DocumentLayout?,
         images: TranscriptImageStore?) {
        self.width = width
        self.style = style
        self.document = document
        let imageRevision = images?.revision ?? 0
        self.imageRevision = imageRevision
        images?.keepFormulas(of: document)

        // A line-limited layout may hold a block cut short, so it is not reused.
        let previous = style.lineLimit == nil ? previous.flatMap { $0.width == width && $0.style == style ? $0 : nil } : nil
        let limit = style.lineLimit.map { max($0, 1) }
        var shownLines = 0
        var settled = SharedList<Entry>()
        var open: [Entry] = []
        var y: CGFloat = 0
        var start = 0
        var reused = 0

        // Settled entries are carried over without a look, unless pictures
        // have arrived since (a block with an image may then change height)
        // or a link reference was defined (a block may restyle a reference).
        let definitions = document.linkDefinitions
        if let previous, previous.imageRevision == imageRevision, previous.document.linkDefinitions == definitions {
            let known = min(document.knownSharedPrefix(with: previous.document), previous.settled.count)
            if known > 0 {
                settled = previous.settled.prefix(known)
                let last = settled[known - 1]
                y = last.y + last.layout.height
                start = last.end + 1
                reused = known
            }
        }

        var previousBlock: TranscriptBlock? = settled.last?.layout.block
        for index in settled.count..<document.count {
            let block = document.block(at: index)
            // Blocks keep their position from one update to the next, so the
            // previous layout for index i is the candidate for block i.
            let candidate = previous.flatMap { index < $0.entryCount ? $0.entry(at: index).layout : nil }
            if let limit, shownLines >= limit { break }
            var layout: BlockLayout
            if let candidate, candidate.block == block, candidate.imageRevision == nil || candidate.imageRevision == imageRevision,
               candidate.definedReferences == nil || candidate.definedReferences == BlockLayout.definedReferences(of: block, in: definitions) {
                layout = candidate
                reused += 1
            } else {
                layout = BlockLayout(block: block, width: width, style: style, reusing: candidate, images: images, definitions: definitions)
            }
            var reachedLimit = false
            if let limit, layout.table == nil {
                let remaining = limit - shownLines
                if layout.lines.count > remaining || (layout.lines.count == remaining && index + 1 < document.count) {
                    layout = BlockLayout(layout, keepingLines: remaining, ellipsis: true)
                    reachedLimit = true
                }
            }
            shownLines += layout.lines.count
            if let previousBlock {
                y += Self.spacing(between: previousBlock, and: block, style: style)
            }
            let entry = Entry(layout: layout, y: y, start: start)
            if index < document.settled.count {
                settled.append(entry)
            } else {
                open.append(entry)
            }
            previousBlock = block
            y += layout.height
            start += layout.length + 1
            if reachedLimit { break }
        }

        self.settled = settled
        self.open = open
        self.height = y
        self.length = max(start - 1, 0)
        self.reusedBlockCount = reused
        self.glyphBottom = y < TileGrid.height ? Self.glyphBottom(of: Array(settled) + open) : y
    }

    private static func glyphBottom(of entries: [Entry]) -> CGFloat {
        var bottom: CGFloat = 0
        for entry in entries {
            for line in entry.layout.lines {
                let glyphs = CTLineGetBoundsWithOptions(line.ctLine, .useGlyphPathBounds)
                guard !glyphs.isNull, !glyphs.isEmpty else { continue }
                // Core Text measures up from the baseline.
                bottom = max(bottom, entry.y + line.baseline - glyphs.minY)
            }
        }
        return bottom
    }

    /// The next item of a list sits closer to the list content above it than
    /// blocks otherwise do.
    private static func spacing(between previous: TranscriptBlock, and next: TranscriptBlock, style: TranscriptStyle) -> CGFloat {
        previous.listLevel > 0 && next.listLevel > 0 && next.marker != nil ? style.listItemSpacing : style.blockSpacing
    }

    /// Whether `a` and `b` are inside the same block quote at container
    /// index `index`, so its bar runs on from one to the other.
    private static func shareQuote(_ a: TranscriptBlock, _ b: TranscriptBlock, at index: Int) -> Bool {
        a.containers.count > index && b.containers.count > index && a.containers[...index] == b.containers[...index]
    }

    /// Whether a line limit left some of the document's text out.
    var leavesTextOut: Bool { length < document.utf16Count }

    /// The part of the document that a selection of this layout stands for.
    /// Under a line limit, a selection that reaches the end of the text
    /// shown also covers the text that the limit leaves out, so Select All
    /// followed by Copy copies all of the text.
    func documentRange(forSelection range: Range<Int>) -> Range<Int> {
        guard !range.isEmpty, range.upperBound >= length, leavesTextOut else { return range }
        return range.lowerBound..<document.utf16Count
    }

    // MARK: Offsets and geometry

    /// The last entry whose `key` is at most `value`, by binary search;
    /// `key` must not decrease with the index.
    private func lastEntryIndex(where key: (Entry) -> CGFloat, isAtMost value: CGFloat) -> Int? {
        guard entryCount > 0 else { return nil }
        var low = 0
        var high = entryCount - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if key(entry(at: mid)) <= value { low = mid } else { high = mid - 1 }
        }
        return low
    }

    private func entryIndex(forOffset offset: Int) -> Int? {
        lastEntryIndex(where: { CGFloat($0.start) }, isAtMost: CGFloat(offset))
    }

    /// The index of the entry of the block with `id`. `hint` is where it was
    /// last, which is checked first.
    func entryIndex(ofBlock id: String, hint: Int? = nil) -> Int? {
        if let hint, hint >= 0, hint < entryCount, entry(at: hint).layout.block.id == id { return hint }
        return (0..<entryCount).last { entry(at: $0).layout.block.id == id }
    }

    /// The index of the entry whose block scrolls sideways at `point`: its
    /// lines are wider than its box, and the point is inside the box.
    func sideScrollingEntryIndex(at point: CGPoint) -> Int? {
        guard let index = lastEntryIndex(where: { $0.y }, isAtMost: point.y) else { return nil }
        let entry = entry(at: index)
        guard entry.layout.maximumScrollOffset > 0, point.y < entry.frame.maxY else { return nil }
        let box = entry.layout.scrollBox
        return point.x >= box.minX && point.x < box.maxX ? index : nil
    }

    /// Whether `a` and `b` scroll alike every block that reaches below `y`,
    /// shapes' overhang included: drawn with either, that part looks the same.
    func scrollsAlike(_ a: SideScroll, _ b: SideScroll, below y: CGFloat) -> Bool {
        guard a != b else { return true }
        return scrollsAlike(a, b, from: lastEntryIndex(where: { $0.y }, isAtMost: y - TranscriptPath.maximumOverhang) ?? 0)
    }

    /// Whether `a` and `b` scroll alike every block with text at or after `offset`.
    func scrollsAlike(_ a: SideScroll, _ b: SideScroll, fromOffset offset: Int) -> Bool {
        guard a != b else { return true }
        return scrollsAlike(a, b, from: entryIndex(forOffset: offset) ?? 0)
    }

    private func scrollsAlike(_ a: SideScroll, _ b: SideScroll, from first: Int) -> Bool {
        (first..<entryCount).allSatisfy {
            let layout = entry(at: $0).layout
            return a.offset(of: layout) == b.offset(of: layout)
        }
    }

    /// The lines with text at or after `offset`, in order, with their blocks.
    func lines(from offset: Int) -> [(entry: Entry, line: BlockLayout.Line)] {
        guard let first = entryIndex(forOffset: offset) else { return [] }
        var result: [(entry: Entry, line: BlockLayout.Line)] = []
        for index in first..<entryCount {
            let entry = entry(at: index)
            for line in entry.layout.lines where !line.range.isEmpty && entry.start + line.range.upperBound > offset {
                result.append((entry, line))
            }
        }
        return result
    }

    public func caretRect(at offset: Int) -> CGRect {
        caretRect(at: offset, scroll: .none)
    }

    /// The caret at `offset` with blocks scrolled sideways by `scroll`. In a
    /// block that scrolls, a caret outside the block's box is moved to its edge.
    func caretRect(at offset: Int, scroll: SideScroll) -> CGRect {
        guard let index = entryIndex(forOffset: offset) else {
            return CGRect(x: 0, y: 0, width: 2, height: style.effectiveBodySize * 1.2)
        }
        let entry = entry(at: index)
        let local = min(max(offset - entry.start, 0), entry.layout.length)
        let rect = entry.layout.caretRect(atOffset: local).offsetBy(dx: 0, dy: entry.y)
        guard entry.layout.maximumScrollOffset > 0 else { return rect }
        let box = entry.layout.scrollBox
        var shifted = rect.offsetBy(dx: -scroll.offset(of: entry.layout), dy: 0)
        shifted.origin.x = min(max(shifted.minX, box.minX), box.maxX - shifted.width)
        return shifted
    }

    public func closestOffset(to point: CGPoint) -> Int {
        closestOffset(to: point, scroll: .none)
    }

    /// The offset nearest to `point`, with blocks scrolled sideways by `scroll`.
    func closestOffset(to point: CGPoint, scroll: SideScroll) -> Int {
        guard var index = lastEntryIndex(where: { $0.y }, isAtMost: point.y) else { return 0 }
        // A point in the gap below a block goes to whichever block is nearer.
        if index + 1 < entryCount {
            let current = entry(at: index)
            let next = entry(at: index + 1)
            if point.y >= (current.frame.maxY + next.y) / 2 { index += 1 }
        }
        let entry = entry(at: index)
        let local = entry.layout.closestOffset(to: CGPoint(x: point.x + scroll.offset(of: entry.layout), y: point.y - entry.y))
        return entry.start + local
    }

    /// The destination of the link drawn under `point`, if any.
    public func link(at point: CGPoint) -> String? {
        link(at: point, scroll: .none)
    }

    /// The destination of the link drawn under `point`, with blocks scrolled
    /// sideways by `scroll`. In a block that scrolls, only its box shows links.
    func link(at point: CGPoint, scroll: SideScroll) -> String? {
        guard let index = lastEntryIndex(where: { $0.y }, isAtMost: point.y) else { return nil }
        let entry = entry(at: index)
        guard entry.frame.contains(point) else { return nil }
        if entry.layout.maximumScrollOffset > 0 {
            let box = entry.layout.scrollBox
            guard point.x >= box.minX, point.x < box.maxX else { return nil }
        }
        let local = CGPoint(x: point.x + scroll.offset(of: entry.layout), y: point.y - entry.y)
        if let link = entry.layout.decorationLink(at: local) { return link }
        guard let offset = entry.layout.characterOffset(at: local) else { return nil }
        // A reference link's destination may have been defined further down.
        return entry.layout.block.spans.lazy
            .filter { $0.range.contains(offset) }
            .compactMap { self.document.destination(of: $0) }
            .first
    }

    /// One rect per line covered by `range`, across as many blocks as it spans.
    public func selectionRects(for range: Range<Int>) -> [CGRect] {
        selectionRects(for: range, scroll: .none)
    }

    /// One rect per line covered by `range`, with blocks scrolled sideways by
    /// `scroll`. In a block that scrolls, the rects are cut to its box; a rect
    /// outside the box becomes an empty one at its edge.
    func selectionRects(for range: Range<Int>, scroll: SideScroll) -> [CGRect] {
        guard !range.isEmpty, let first = entryIndex(forOffset: range.lowerBound) else { return [] }
        var rects: [CGRect] = []
        for index in first..<entryCount {
            let entry = entry(at: index)
            if entry.start >= range.upperBound { break }
            let lower = max(range.lowerBound - entry.start, 0)
            let upper = min(range.upperBound - entry.start, entry.layout.length)
            guard lower < upper else { continue }
            let scrolls = entry.layout.maximumScrollOffset > 0
            let dx = scroll.offset(of: entry.layout)
            let box = entry.layout.scrollBox
            for rect in entry.layout.selectionRects(for: lower..<upper) {
                var shifted = rect.offsetBy(dx: -dx, dy: entry.y)
                if scrolls {
                    let minX = min(max(shifted.minX, box.minX), box.maxX)
                    let maxX = min(max(shifted.maxX, box.minX), box.maxX)
                    shifted.origin.x = minX
                    shifted.size.width = maxX - minX
                }
                rects.append(shifted)
            }
        }
        return rects
    }

    /// The top of the first line that differs between `earlier` and this
    /// layout, assuming everything before it is identical (as after an
    /// append). Lines are compared by identity, so this is cheap.
    func firstChangedY(since earlier: DocumentLayout) -> CGFloat {
        changes(since: earlier).top
    }

    /// What differs from `earlier` after an append: the top of the first
    /// change in the flow of the text, and above it, blocks drawn differently
    /// in place (a reference styled once its definition arrived), by their
    /// frames. Redrawing those frames and everything from `top` down gives
    /// this layout's drawing.
    func changes(since earlier: DocumentLayout) -> (top: CGFloat, restyled: [CGRect]) {
        var restyled: [CGRect] = []
        var index = min(document.knownSharedPrefix(with: earlier.document), earlier.settled.count, settled.count)
        // A new link definition may have restyled a block anywhere above.
        let definitionsChanged = document.linkDefinitions != earlier.document.linkDefinitions
        if definitionsChanged { index = 0 }
        let top = firstChange(since: earlier, from: index) { new, old in
            // Same place, same size, same lines: only the styling changed.
            guard definitionsChanged, new.y == old.y, new.layout.height == old.layout.height,
                  new.layout.lines.count == old.layout.lines.count,
                  zip(new.layout.lines, old.layout.lines).allSatisfy({ $0.range == $1.range && $0.frame == $1.frame }) else { return false }
            // Tags' shapes may reach a little past the block.
            restyled.append(new.frame.insetBy(dx: 0, dy: -TranscriptPath.maximumOverhang))
            return true
        }
        return (top, restyled)
    }

    private func firstChange(since earlier: DocumentLayout, from start: Int, isRestyle: (Entry, Entry) -> Bool) -> CGFloat {
        var index = start
        // A block that comes or goes also changes the gap above it, where a
        // quote bar may run on from the block before.
        func gapAbove(_ index: Int, in layout: DocumentLayout) -> CGFloat {
            index > 0 ? layout.entry(at: index - 1).frame.maxY : layout.entry(at: index).y
        }
        while index < min(entryCount, earlier.entryCount) {
            let new = entry(at: index)
            let old = earlier.entry(at: index)
            guard new.y == old.y else { return min(gapAbove(index, in: self), gapAbove(index, in: earlier)) }
            if new.layout === old.layout || isRestyle(new, old) {
                index += 1
                continue
            }
            if new.layout.table != nil || old.layout.table != nil {
                return new.y + Self.firstChangedY(in: new.layout, since: old.layout)
            }
            // From the top of what a line draws, which its tags' shapes may raise.
            for (newLine, oldLine) in zip(new.layout.lines, old.layout.lines) where newLine.ctLine !== oldLine.ctLine {
                return new.y + min(newLine.inkTop, oldLine.inkTop)
            }
            let shorter = min(new.layout.lines.count, old.layout.lines.count)
            if shorter < new.layout.lines.count { return new.y + new.layout.lines[shorter].inkTop }
            if shorter < old.layout.lines.count { return old.y + old.layout.lines[shorter].inkTop }
            return new.y + min(new.layout.height, old.layout.height)
        }
        if index < entryCount { return gapAbove(index, in: self) }
        if index < earlier.entryCount { return gapAbove(index, in: earlier) }
        return min(height, earlier.height)
    }

    /// Within a table block: the top of the first row drawn differently,
    /// or 0 if the columns changed and with them the whole grid.
    private static func firstChangedY(in new: BlockLayout, since old: BlockLayout) -> CGFloat {
        guard let a = new.table, let b = old.table, a.columnX == b.columnX else { return 0 }
        let shared = min(a.cellLines.count, b.cellLines.count)
        var row = 0
        rows: while row < shared {
            guard a.cellLines[row] == b.cellLines[row], a.rowY[row + 1] == b.rowY[row + 1] else { break }
            for cell in a.cellLines[row] {
                for index in cell where new.lines[index].ctLine !== old.lines[index].ctLine { break rows }
            }
            row += 1
        }
        guard row < a.rowY.count, row < b.rowY.count else { return min(new.height, old.height) }
        return max(min(a.rowY[row], b.rowY[row]) - BlockLayout.Table.changeMargin, 0)
    }

    // MARK: Drawing

    /// Draws the blocks intersecting `dirtyRect` into a top-left-origin context.
    /// `accent` colors quote bars and rules, and `codeBackground` code blocks
    /// and table headers, unless the style sets their own colors. `dark`
    /// picks the dark values of the style's colors and custom tags' colors,
    /// and `highContrast` their Increase Contrast values.
    public func draw(in context: CGContext, dirtyRect: CGRect, text: CGColor, codeBackground: CGColor, accent: CGColor,
                     dark: Bool = false, highContrast: Bool = false) {
        draw(in: context, dirtyRect: dirtyRect, text: text, codeBackground: codeBackground, accent: accent, dark: dark,
             highContrast: highContrast, hiding: .none)
    }

    /// - Parameter hiding: animated tags whose animation is playing, drawn
    ///   above the text instead (their glyphs and shapes are left out), or
    ///   waiting to play (their shapes are left out).
    /// - Parameter scroll: how far blocks that scroll sideways are scrolled.
    ///   Their lines are drawn moved left by it, inside their box.
    func draw(in context: CGContext, dirtyRect: CGRect, text: CGColor, codeBackground: CGColor, accent: CGColor,
              dark: Bool, highContrast: Bool, hiding: TagHiding, scroll: SideScroll = .none) {
        context.saveGState()
        defer { context.restoreGState() }
        // Core Text draws y-up; flip glyphs so they are upright in a y-down context.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        // Custom tags' highlights and inline code fills, behind the whole
        // line's glyphs. Runs next to each other with the same fill share one
        // highlight, and it stays within the line, so drawing a band of lines
        // never cuts one off.
        func drawHighlights(_ runs: [CTRun], at origin: CGPoint) {
            var current: (rect: CGRect, color: TranscriptColor, radius: CGFloat)?
            func flush() {
                guard let highlight = current else { return }
                current = nil
                context.saveGState()
                context.setFillColor(highlight.color.cgColor(dark: dark, highContrast: highContrast))
                let rect = highlight.rect.insetBy(dx: -1.5, dy: 0)
                let radius = min(max(highlight.radius, 0), rect.width / 2, rect.height / 2)
                context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.fillPath()
                context.restoreGState()
            }
            for run in runs {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                let tag = attributes[Self.backgroundKey] as? TranscriptColor
                guard let color = tag ?? attributes[Self.inlineCodeBackgroundKey] as? TranscriptColor, attributes[Self.imageKey] == nil,
                      let font = attributes[kCTFontAttributeName].map({ $0 as! CTFont }) else {
                    flush()
                    continue
                }
                let radius: CGFloat = tag != nil ? 3 : style.inlineCodeCornerRadius
                var position = CGPoint.zero
                CTRunGetPositions(run, CFRange(location: 0, length: 1), &position)
                let width = CGFloat(CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), nil, nil, nil))
                let ascent = CTFontGetAscent(font)
                let rect = CGRect(x: origin.x + position.x, y: origin.y - ascent, width: width, height: ascent + CTFontGetDescent(font))
                if let highlight = current, highlight.color == color, highlight.radius == radius, abs(highlight.rect.maxX - rect.minX) < 0.5 {
                    current = (highlight.rect.union(rect), color, radius)
                } else {
                    flush()
                    current = (rect, color, radius)
                }
            }
            flush()
        }

        // Drawn run by run: a run with its own color (a link) leaves that color
        // set on the context, so the text color is restored before each run.
        // Strikethrough and underline are drawn here too; images separately.
        // The glyphs for the characters in `hidden` (the line's string
        // indexes) are left out.
        func drawLine(_ line: CTLine, at origin: CGPoint, hidden: [Range<Int>] = [], visible: ClosedRange<CGFloat>? = nil) {
            drawHighlights(CTLineGetGlyphRuns(line) as! [CTRun], at: origin)
            Self.drawGlyphs(of: line, at: origin, hidden: hidden, visible: visible, in: context, text: text, dark: dark,
                            highContrast: highContrast)
        }

        func fill(_ rect: CGRect, radius: CGFloat, color: CGColor) {
            context.saveGState()
            context.setFillColor(color)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
            context.restoreGState()
        }

        /// A line's tag images, clipped like its shapes.
        func drawTagImages(of line: BlockLayout.Line, in entry: Entry, shift: CGFloat) {
            guard let decorations = line.decorations, !decorations.images.isEmpty else { return }
            context.saveGState()
            let side = TranscriptPath.maximumSideOverhang
            context.clip(to: CGRect(x: shift - side, y: entry.y + line.frame.minY - decorations.inkAbove, width: entry.layout.width + 2 * side,
                                    height: line.frame.height + decorations.inkAbove + decorations.inkBelow))
            context.translateBy(x: line.frame.minX, y: entry.y + line.baseline)
            for item in decorations.images {
                if !hiding.isEmpty, let owner = item.tag, hiding.hidesShapes(of: owner) { continue }
                context.saveGState()
                // The context is y-down; CGContext draws images y-up.
                context.translateBy(x: item.rect.minX, y: item.rect.maxY)
                context.scaleBy(x: 1, y: -1)
                let box = CGRect(origin: .zero, size: item.rect.size)
                context.interpolationQuality = .high
                if let tint = item.image.tint {
                    context.clip(to: box, mask: item.image.image)
                    context.setFillColor(tint.cgColor(dark: dark, highContrast: highContrast))
                    context.fill(box)
                } else {
                    context.draw(item.image.image, in: box)
                }
                context.restoreGState()
            }
            context.restoreGState()
        }

        /// A line's tag shapes on one layer, clipped to what the line may
        /// draw, as invalidation knows it. `shift` is how far the context
        /// was moved left for a block that scrolls sideways.
        func drawShapes(of line: BlockLayout.Line, in entry: Entry, over: Bool, shift: CGFloat) {
            guard let decorations = line.decorations else { return }
            let paths = over ? decorations.over : decorations.behind
            guard !paths.isEmpty else { return }
            let owners = over ? decorations.overTags : decorations.behindTags
            context.saveGState()
            let side = TranscriptPath.maximumSideOverhang
            context.clip(to: CGRect(x: shift - side, y: entry.y + line.frame.minY - decorations.inkAbove, width: entry.layout.width + 2 * side,
                                    height: line.frame.height + decorations.inkAbove + decorations.inkBelow))
            context.translateBy(x: line.frame.minX, y: entry.y + line.baseline)
            for (index, path) in paths.enumerated() {
                if !hiding.isEmpty, index < owners.count, let owner = owners[index], hiding.hidesShapes(of: owner) { continue }
                path.draw(in: context, dark: dark, highContrast: highContrast)
            }
            context.restoreGState()
        }

        // Tags' shapes may reach a little outside their block.
        let overhang = TranscriptPath.maximumOverhang
        // Binary search for the first block that reaches into the dirty rect.
        var low = 0
        var high = entryCount
        while low < high {
            let mid = (low + high) / 2
            if entry(at: mid).frame.maxY + overhang < dirtyRect.minY { low = mid + 1 } else { high = mid }
        }

        for index in low..<entryCount {
            let entry = entry(at: index)
            let frame = entry.frame
            // A quote bar fills the gap above a block, so a block just below
            // the dirty rect may still draw into it.
            if frame.minY > dirtyRect.maxY + max(style.blockSpacing, overhang) { break }
            let layout = entry.layout
            let block = layout.block

            // Quote bars, run on through the gap from the block above when it
            // is in the same quote.
            let above = index > 0 ? self.entry(at: index - 1) : nil
            let bar = style.quoteBarColor?.cgColor(dark: dark, highContrast: highContrast) ?? accent
            var x: CGFloat = 0
            for (depth, container) in block.containers.enumerated() {
                if container == .quote {
                    var top = frame.minY
                    if let above, Self.shareQuote(above.layout.block, block, at: depth) { top = above.frame.maxY }
                    // Square ends, so that segments of one bar meet cleanly.
                    fill(CGRect(x: x, y: top, width: max(style.quoteBarWidth, 0), height: frame.maxY - top), radius: 0, color: bar)
                }
                x += style.width(of: container)
            }
            if frame.minY - overhang > dirtyRect.maxY { break }

            let box = CGRect(x: layout.contentLeading, y: frame.minY, width: max(frame.width - layout.contentLeading, 0), height: frame.height)
            switch block.kind {
            case .code:
                fill(box, radius: 8, color: codeBackground)
            case .rule:
                fill(CGRect(x: box.minX, y: frame.midY - 0.5, width: box.width, height: 1), radius: 0, color: accent)
            case .table:
                if let table = layout.table {
                    let header = style.tableHeaderBackgroundColor?.cgColor(dark: dark, highContrast: highContrast) ?? codeBackground
                    drawGrid(table, top: entry.y, in: context, header: header, lines: accent)
                }
            case .paragraph, .heading:
                break
            }

            let lines = layout.lines
            let visible: Range<Int>
            if layout.table != nil {
                // A table's lines are not in order of y; it is drawn whole.
                visible = 0..<lines.count
            } else {
                // Only the lines near the dirty rect: drawing a whole block and
                // letting the context clip it costs as much as drawing it all.
                // A line's height of margin (at least 8 points, more than tags'
                // shapes may overhang) keeps glyphs that reach beyond their line
                // box (accents, descenders, emoji) from being cut off.
                func isAbove(_ line: BlockLayout.Line) -> Bool {
                    entry.y + line.frame.maxY + max(line.frame.height, 8) < dirtyRect.minY
                }
                var first = 0
                var last = lines.count
                while first < last {
                    let mid = (first + last) / 2
                    if isAbove(lines[mid]) { first = mid + 1 } else { last = mid }
                }
                var end = first
                while end < lines.count, entry.y + lines[end].frame.minY - max(lines[end].frame.height, 8) <= dirtyRect.maxY { end += 1 }
                visible = first..<end
            }

            // The lines of a block that scrolls sideways, moved by its offset
            // and cut to its box.
            let scrolls = layout.maximumScrollOffset > 0
            let dx = scroll.offset(of: layout)
            func inScrolledBox(_ body: () -> Void) {
                guard scrolls else { return body() }
                context.saveGState()
                context.clip(to: CGRect(x: box.minX, y: frame.minY - overhang, width: box.width, height: frame.height + 2 * overhang))
                context.translateBy(x: -dx, y: 0)
                body()
                context.restoreGState()
            }

            // Behind the text: tags' shapes, so that none covers a glyph of
            // the line above; then the text; then shapes over it.
            inScrolledBox {
                for index in visible {
                    drawShapes(of: lines[index], in: entry, over: false, shift: dx)
                    drawTagImages(of: lines[index], in: entry, shift: dx)
                }
            }

            switch layout.marker {
            case .text(let line, let origin)?:
                drawLine(line, at: CGPoint(x: origin.x, y: entry.y + origin.y))
            case .checkbox(let rect, let checked)?:
                let item = block.containers.lastIndex(of: .listItem) ?? 0
                let color = style.textColor(inside: block.containers[..<item])?.cgColor(dark: dark, highContrast: highContrast) ?? text
                drawCheckbox(rect.offsetBy(dx: 0, dy: entry.y), checked: checked, in: context, text: color, dark: dark,
                             highContrast: highContrast)
            case nil:
                break
            }

            inScrolledBox {
                for index in visible where !lines[index].range.isEmpty {
                    let line = lines[index]
                    var hidden = line.decorations?.hiddenRanges(hiding.playing) ?? []
                    if let from = hiding.fadingFrom, entry.start + line.range.upperBound > from {
                        hidden.append(max(from - entry.start, line.range.lowerBound)..<line.range.upperBound)
                    }
                    // A line much wider than the box draws only the glyphs near it.
                    let reach = 2 * max(line.frame.height, 8)
                    let visible = scrolls && line.frame.width > box.width
                        ? (box.minX + dx - reach)...(box.maxX + dx + reach) : nil
                    drawLine(line.ctLine, at: CGPoint(x: line.frame.minX, y: entry.y + line.baseline),
                             hidden: hidden.map { ($0.lowerBound - line.indexBase)..<($0.upperBound - line.indexBase) },
                             visible: visible)
                }

                let imageText = layout.attachments.isEmpty ? text : style.textColor(inside: block.containers)?.cgColor(dark: dark, highContrast: highContrast) ?? text
                for attachment in layout.attachments {
                    let rect = attachment.rect.offsetBy(dx: 0, dy: entry.y)
                    guard rect.offsetBy(dx: -dx, dy: 0).intersects(dirtyRect) else { continue }
                    drawImage(attachment.attachment, in: rect, context: context, text: imageText, background: codeBackground)
                }

                for index in visible { drawShapes(of: lines[index], in: entry, over: true, shift: dx) }
            }
        }
    }

    /// The fill color a run's glyphs are drawn with: the tag's own color, or
    /// the text's. A run with a color attribute (a link) uses that instead.
    static func setGlyphColor(of attributes: NSDictionary, in context: CGContext, text: CGColor, dark: Bool, highContrast: Bool) {
        let custom = (attributes[foregroundKey] as? TranscriptColor)?.cgColor(dark: dark, highContrast: highContrast)
        context.setFillColor(custom ?? text)
    }

    /// Draws a line's glyphs, and their strikethrough and underline, leaving
    /// out the characters in `hidden` (line string indexes). Images are left
    /// to the caller. The context's text matrix must flip glyphs upright.
    /// - Parameter visible: if set, only the glyphs that start in this range
    ///   of x are drawn.
    static func drawGlyphs(of line: CTLine, at origin: CGPoint, hidden: [Range<Int>], visible: ClosedRange<CGFloat>? = nil,
                           in context: CGContext, text: CGColor, dark: Bool, highContrast: Bool) {
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            if attributes[imageKey] != nil { continue }
            var ranges = hidden.isEmpty ? [CFRange(location: 0, length: 0)] : glyphRanges(of: run, leavingOut: hidden)
            if let visible {
                guard let shown = glyphRange(of: run, startingIn: (visible.lowerBound - origin.x)...(visible.upperBound - origin.x))
                else { continue }
                let count = CTRunGetGlyphCount(run)
                ranges = ranges.compactMap {
                    let lower = max($0.location, shown.lowerBound)
                    let upper = min($0.length == 0 ? count : $0.location + $0.length, shown.upperBound)
                    return lower < upper ? CFRange(location: lower, length: upper - lower) : nil
                }
            }
            guard !ranges.isEmpty else { continue }
            setGlyphColor(of: attributes, in: context, text: text, dark: dark, highContrast: highContrast)
            context.textPosition = origin
            for range in ranges { CTRunDraw(run, context, range) }
            let custom = (attributes[foregroundKey] as? TranscriptColor)?.cgColor(dark: dark, highContrast: highContrast)
            let strike = attributes[strikethroughKey] != nil
            let underline = attributes[underlineKey] != nil
            guard strike || underline, let font = attributes[kCTFontAttributeName].map({ $0 as! CTFont }) else { continue }
            let color = custom ?? attributes[kCTForegroundColorAttributeName].map { $0 as! CGColor } ?? text
            let thickness = max(CTFontGetUnderlineThickness(font), 1)
            context.setFillColor(color)
            // Ends on whole pixels, so that a line drawn in two parts (some
            // of its text fading in) covers the same pixels as one.
            func fill(x: CGFloat, y: CGFloat, width: CGFloat) {
                var device = context.convertToDeviceSpace(CGRect(x: x, y: y, width: width, height: thickness))
                let minX = device.minX.rounded()
                device.size.width = device.maxX.rounded() - minX
                device.origin.x = minX
                guard device.width > 0 else { return }
                context.fill(context.convertToUserSpace(device))
            }
            for range in ranges {
                var position = CGPoint.zero
                CTRunGetPositions(run, CFRange(location: range.location, length: 1), &position)
                let width = CGFloat(CTRunGetTypographicBounds(run, range, nil, nil, nil))
                if strike { fill(x: origin.x + position.x, y: origin.y - CTFontGetXHeight(font) / 2 - thickness / 2, width: width) }
                if underline { fill(x: origin.x + position.x, y: origin.y - CTFontGetUnderlinePosition(font), width: width) }
            }
        }
    }

    /// The glyphs of `run` from the first to the last whose position, in its
    /// line, is in `range`; nil if none is.
    static func glyphRange(of run: CTRun, startingIn range: ClosedRange<CGFloat>) -> Range<Int>? {
        let count = CTRunGetGlyphCount(run)
        func find(in positions: UnsafeBufferPointer<CGPoint>) -> Range<Int>? {
            guard let first = positions.firstIndex(where: { range.contains($0.x) }),
                  let last = positions.lastIndex(where: { range.contains($0.x) }) else { return nil }
            return first..<(last + 1)
        }
        if let pointer = CTRunGetPositionsPtr(run) { return find(in: UnsafeBufferPointer(start: pointer, count: count)) }
        var positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
        return positions.withUnsafeBufferPointer(find)
    }

    /// The runs of `run`'s glyphs whose characters are not in `hidden`.
    static func glyphRanges(of run: CTRun, leavingOut hidden: [Range<Int>]) -> [CFRange] {
        let count = CTRunGetGlyphCount(run)
        let stringRange = CTRunGetStringRange(run)
        let runChars = stringRange.location..<(stringRange.location + stringRange.length)
        guard hidden.contains(where: { $0.overlaps(runChars) }) else { return [CFRange(location: 0, length: 0)] }
        var indices = [CFIndex](repeating: 0, count: count)
        CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
        var ranges: [CFRange] = []
        var start: Int?
        for glyph in 0..<count {
            let shown = !hidden.contains { $0.contains(indices[glyph]) }
            if shown, start == nil { start = glyph }
            if !shown, let first = start {
                ranges.append(CFRange(location: first, length: glyph - first))
                start = nil
            }
        }
        if let first = start { ranges.append(CFRange(location: first, length: count - first)) }
        return ranges
    }

    private static let imageKey = TranscriptStyle.imageKey.rawValue
    private static let strikethroughKey = TranscriptStyle.strikethroughKey.rawValue
    private static let underlineKey = TranscriptStyle.underlineKey.rawValue
    private static let foregroundKey = TranscriptStyle.foregroundKey.rawValue
    private static let backgroundKey = TranscriptStyle.backgroundKey.rawValue
    private static let inlineCodeBackgroundKey = TranscriptStyle.inlineCodeBackgroundKey.rawValue

    private func drawGrid(_ table: BlockLayout.Table, top: CGFloat, in context: CGContext, header: CGColor, lines: CGColor) {
        let frame = table.frame.offsetBy(dx: 0, dy: top)
        guard frame.width > 0, table.rowY.count > 1 else { return }
        let outline = CGPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 6, cornerHeight: 6, transform: nil)
        // The header row's background and the inner lines, inside the
        // rounded outline. The clip is undone by restoring the state, not
        // reset: the caller's clip to the band being drawn must stay.
        context.saveGState()
        context.addPath(outline)
        context.clip()
        context.setFillColor(header)
        context.fill(CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: table.rowY[1] - table.rowY[0]))
        context.setFillColor(lines)
        for y in table.rowY.dropFirst().dropLast() {
            context.fill(CGRect(x: frame.minX, y: top + y - 0.5, width: frame.width, height: 1))
        }
        for x in table.columnX.dropFirst().dropLast() {
            context.fill(CGRect(x: x - 0.5, y: frame.minY, width: 1, height: frame.height))
        }
        context.restoreGState()
        context.saveGState()
        context.addPath(outline)
        context.setStrokeColor(lines)
        context.setLineWidth(1)
        context.strokePath()
        context.restoreGState()
    }

    private func drawCheckbox(_ rect: CGRect, checked: Bool, in context: CGContext, text: CGColor, dark: Bool, highContrast: Bool) {
        context.saveGState()
        let box = CGPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), cornerWidth: 4, cornerHeight: 4, transform: nil)
        if checked {
            context.setFillColor(style.taskCheckedColor?.cgColor(dark: dark, highContrast: highContrast) ?? CGColor(red: 0, green: 0.478, blue: 1, alpha: 1))
            context.addPath(box)
            context.fillPath()
            let check = CGMutablePath()
            check.move(to: CGPoint(x: rect.minX + rect.width * 0.25, y: rect.minY + rect.height * 0.52))
            check.addLine(to: CGPoint(x: rect.minX + rect.width * 0.43, y: rect.minY + rect.height * 0.7))
            check.addLine(to: CGPoint(x: rect.minX + rect.width * 0.76, y: rect.minY + rect.height * 0.32))
            context.addPath(check)
            context.setStrokeColor(style.taskCheckmarkColor?.cgColor(dark: dark, highContrast: highContrast) ?? CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.setLineWidth(max(rect.width * 0.12, 1.5))
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()
        } else {
            context.addPath(box)
            context.setStrokeColor(style.taskUncheckedColor?.cgColor(dark: dark, highContrast: highContrast) ?? text.copy(alpha: 0.45) ?? text)
            context.setLineWidth(1.5)
            context.strokePath()
        }
        context.restoreGState()
    }

    private func drawImage(_ attachment: ImageAttachment, in rect: CGRect, context: CGContext, text: CGColor, background: CGColor) {
        context.saveGState()
        defer { context.restoreGState() }
        if let picture = attachment.picture {
            // The context is y-down; CGContext draws images y-up.
            context.translateBy(x: rect.minX, y: rect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .high
            let box = CGRect(origin: .zero, size: rect.size)
            if attachment.isMask {
                context.clip(to: box, mask: picture)
                context.setFillColor(text)
                context.fill(box)
            } else {
                context.draw(picture, in: box)
            }
            return
        }
        // No picture: a chip with the alt text, or for a formula being drawn, nothing.
        guard let label = attachment.label else { return }
        context.setFillColor(background)
        context.addPath(CGPath(roundedRect: rect.insetBy(dx: 0, dy: 1), cornerWidth: 5, cornerHeight: 5, transform: nil))
        context.fillPath()
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        CTLineGetTypographicBounds(label, &ascent, &descent, nil)
        context.setFillColor(text.copy(alpha: 0.7) ?? text)
        context.textPosition = CGPoint(x: rect.minX + 6, y: rect.midY + (ascent - descent) / 2)
        CTLineDraw(label, context)
    }
}
