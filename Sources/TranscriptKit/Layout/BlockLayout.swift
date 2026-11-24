import CoreGraphics
import CoreText
import Foundation

/// Core Text line layout for one block, in block-local, top-left coordinates.
///
/// Offsets are UTF-16 offsets into the block's own text. Immutable once
/// made, so it can be built on one thread and drawn on another.
final class BlockLayout: @unchecked Sendable {
    struct Line {
        let ctLine: CTLine
        /// Core Text's string indexes for `ctLine` are relative to this offset:
        /// a line reused from an earlier layout, or typeset from part of the
        /// text, was made from a string that started here.
        let indexBase: Int
        let range: Range<Int>
        /// Line box: `minX` is where glyphs start, `width` excludes trailing whitespace.
        let frame: CGRect
        let baseline: CGFloat
        /// Shapes custom tags draw on this line; nil for most lines.
        var decorations: LineDecorations? = nil

        /// The top of what is drawn for the line, its tags' shapes included.
        var inkTop: CGFloat { frame.minY - (decorations?.inkAbove ?? 0) }
    }

    /// What marks a list item, drawn in the gutter of its first line.
    enum Marker {
        /// A bullet or number, drawn with its baseline at `origin`.
        case text(CTLine, origin: CGPoint)
        case checkbox(CGRect, checked: Bool)
    }

    /// An image, and where it is drawn.
    struct Attachment {
        let attachment: ImageAttachment
        let rect: CGRect
    }

    /// A table's grid. Its lines are in text order: row by row, cell by cell.
    struct Table {
        /// Left edge of each column, then the right edge of the last one.
        let columnX: [CGFloat]
        /// Top of each row, then the bottom of the last one.
        let rowY: [CGFloat]
        /// For each cell, the indexes of its lines in `lines`.
        let cellLines: [[Range<Int>]]
        /// For each cell, the width it would take on one line, padding included.
        let naturalWidths: [[CGFloat]]
        /// For each cell, the width of its longest word, padding included:
        /// narrower, and a word would have to break.
        let minimumWidths: [[CGFloat]]

        /// How far above a row its drawing can change when the row does: the
        /// separator above it, and the rounded corners if it was the last row.
        static let changeMargin: CGFloat = 8

        var frame: CGRect {
            CGRect(x: columnX[0], y: rowY[0], width: columnX[columnX.count - 1] - columnX[0], height: rowY[rowY.count - 1] - rowY[0])
        }
    }

    let block: TranscriptBlock
    let width: CGFloat
    let style: TranscriptStyle
    /// Shared with the layout this one was made from, if any: a growing block
    /// appends to its earlier lines instead of copying them.
    let lines: SharedList<Line>
    let height: CGFloat
    let length: Int
    /// Where the block's own box starts, after its containers' indents.
    let contentLeading: CGFloat
    let marker: Marker?
    let table: Table?
    let attachments: [Attachment]
    /// For a block with images: the image store's revision when it was laid
    /// out, so it can be redone once their pictures arrive.
    let imageRevision: Int?
    /// For a block with reference links: those whose label was defined when
    /// it was laid out, and so styled as links.
    let definedReferences: Set<String>?

    /// The labels of `block`'s reference links that `definitions` defines,
    /// or nil if it has none.
    static func definedReferences(of block: TranscriptBlock, in definitions: [String: String]) -> Set<String>? {
        var labels: Set<String>?
        for span in block.spans {
            guard let label = span.reference else { continue }
            if labels == nil { labels = [] }
            if definitions[label] != nil { labels!.insert(label) }
        }
        return labels
    }

    var isCode: Bool { block.kind.isCode }

    /// - Parameter previous: an earlier layout of the same block. If `block`
    ///   only adds text at the end, the lines above the last one are reused
    ///   and typesetting restarts at the last line, so the cost of a streaming
    ///   update depends on the line being written, not the block's length.
    init(block: TranscriptBlock, width: CGFloat, style: TranscriptStyle, reusing previous: BlockLayout? = nil,
         images: TranscriptImageStore? = nil, definitions: [String: String] = [:]) {
        self.block = block
        self.width = width
        self.style = style

        let text = block.text as NSString
        let length = text.length
        self.length = length

        let insets = style.insets(for: block)
        let available = max(width - insets.leading - insets.trailing, 1)
        let hasImages = block.spans.contains { $0.image != nil || $0.math != nil }
        // Laid out again when the store's pictures or code colors change.
        let usesStore = hasImages || (block.kind.isCode && images?.hasHighlighter == true)
        let revision = usesStore ? (images?.revision ?? 0) : nil
        let contentLeading = style.contentLeading(for: block.containers)
        let defined = Self.definedReferences(of: block, in: definitions)
        self.definedReferences = defined
        // Earlier lines can be kept only if they were styled the same way.
        let previous = previous.flatMap { $0.definedReferences == defined ? $0 : nil }
        self.imageRevision = revision
        self.contentLeading = contentLeading

        let lines: SharedList<Line>
        if let model = block.kind.table {
            let laidOut = Self.layOutTable(model, block: block, style: style, x: contentLeading, available: available,
                                           blockWidth: width, images: images, definitions: definitions,
                                           reusing: previous.flatMap { $0.width == width && $0.style == style && $0.imageRevision == revision ? $0 : nil })
            lines = laidOut.lines
            self.height = laidOut.height
            self.table = laidOut.table
        } else {
            let sizing = ImageSizing(store: images, maximumWidth: available)
            let laidOut = Self.layOutText(block, style: style, insets: insets, available: available, blockWidth: width,
                                          sizing: sizing, definitions: definitions,
                                          reusing: previous.flatMap { $0.width == width && $0.imageRevision == revision ? $0 : nil })
            lines = laidOut.lines
            self.height = laidOut.height
            self.table = nil
        }
        self.lines = lines
        self.marker = Self.makeMarker(for: block, style: style, firstLine: lines.first)
        self.attachments = hasImages ? Self.findAttachments(in: lines) : []
    }

    // MARK: Text

    private static func layOutText(_ block: TranscriptBlock, style: TranscriptStyle, insets: TranscriptStyle.Insets,
                                   available: CGFloat, blockWidth: CGFloat, sizing: ImageSizing, definitions: [String: String],
                                   reusing previous: BlockLayout?) -> (lines: SharedList<Line>, height: CGFloat) {
        let length = block.utf16Count
        let font = style.font(for: block.kind)
        let hasDecorations = DecoratedTags.appear(in: block)
        var lines = SharedList<Line>()
        var y = insets.vertical
        var restart = 0
        if let previous, previous.style == style, previous.block.isStyledPrefix(of: block), previous.lines.count > 1 {
            // Line breaks are chosen greedily, so appended text can only
            // change the last line and what follows it.
            var keep = previous.lines.count - 1
            // Text that ended in line breaks ends in lines that hold only
            // those, and an empty one for the caret. A tag left open on the
            // last line with text now ends elsewhere, and its shapes and
            // padding with it, so typesetting restarts at that line.
            if hasDecorations {
                let text = previous.block.text as NSString
                func holdsOnlyLineBreaks(_ line: Line) -> Bool {
                    line.range.allSatisfy { text.character(at: $0) == 0x0A }
                }
                while keep > 0, holdsOnlyLineBreaks(previous.lines[keep]) { keep -= 1 }
                // A tag that keeps together may have gone down a line, and
                // may no longer fit on a line of its own: its lines and the
                // line above them are laid out again.
                while keep > 0, DecoratedTags.keepsTogether(at: previous.lines[keep].range.lowerBound, in: block) { keep -= 1 }
            }
            if keep > 0 {
                lines = previous.lines.prefix(keep)
                restart = previous.lines[keep].range.lowerBound
                y = previous.lines[keep].frame.minY
            }
        }

        // Only the tags on the lines laid out again; the others' lines are kept.
        let decorated = hasDecorations ? DecoratedTags(block, from: restart) : nil

        let fixedHeight = style.lineHeight(for: block.kind)
        let gap = fixedHeight == nil ? style.lineSpacing : 0
        let isDisplayMath = block.spans.count == 1 && block.spans[0].math?.isDisplay == true
            && block.text.trimmingCharacters(in: .whitespacesAndNewlines) == "\u{FFFC}"
        func add(_ ctLine: CTLine, range: Range<Int>, indexBase: Int, leading: CGFloat = 0, text: NSAttributedString? = nil) {
            let metrics = fitted(lineMetrics(ctLine, isEmpty: range.isEmpty, font: font), to: fixedHeight)
            let x = insets.leading + leading + (isDisplayMath
                ? max(((available - leading - metrics.width) / 2).rounded(.down), 0)
                : alignmentOffset(block, style: style, width: metrics.width, room: available - leading))
            var decorations: LineDecorations?
            if let decorated, let text {
                decorations = LineDecorations.make(line: ctLine, range: range, indexBase: indexBase, visibleWidth: metrics.width,
                                                   top: -metrics.ascent, bottom: metrics.height - metrics.ascent,
                                                   lineX: x, blockWidth: blockWidth, block: block.id,
                                                   tags: decorated, text: text, textBase: indexBase)
            }
            lines.append(Line(
                ctLine: ctLine,
                indexBase: indexBase,
                range: range,
                frame: CGRect(x: x, y: y, width: metrics.width, height: metrics.height),
                baseline: y + metrics.ascent,
                decorations: decorations
            ))
            y += metrics.height + gap
        }

        if restart < length {
            let attributed = style.attributedString(for: block, from: restart, images: sizing, definitions: definitions,
                                                    kerns: decorated?.kerns ?? [:])
            let typesetter = CTTypesetterCreateWithAttributedString(attributed)
            var start = restart
            while start < length {
                let local = start - restart
                // A padded tag that starts the line has no character before it
                // on the line to carry its padding, so the line moves over.
                func room(at offset: Int) -> CGFloat { min(decorated?.startPadding[offset] ?? 0, available / 2) }
                let leading = room(at: start)
                var count = max(CTTypesetterSuggestLineBreak(typesetter, local, Double(available - leading)), 1)
                if let decorated, start + count < length {
                    count = decorated.lineEnd(from: start, to: start + count) { range in
                        CTTypesetterSuggestLineBreak(typesetter, range.lowerBound - restart, Double(available - room(at: range.lowerBound)))
                            >= range.count
                    } - start
                }
                let ctLine = CTTypesetterCreateLine(typesetter, CFRange(location: local, length: count))
                add(ctLine, range: start..<(start + count), indexBase: restart, leading: leading, text: attributed)
                start += count
            }
        }
        // An empty block, or one ending in a newline, still needs a line for the caret.
        if length == 0 || (block.text as NSString).character(at: length - 1) == 0x0A {
            let empty = CTLineCreateWithAttributedString(NSAttributedString(string: "", attributes: style.attributes(for: block.kind)))
            add(empty, range: length..<length, indexBase: length)
        }
        return (lines, y - gap + insets.vertical)
    }

    /// Line metrics made `height` tall, with the text centred, when the app
    /// set a line height. A line is never less tall than its text needs.
    private static func fitted(_ metrics: (width: CGFloat, height: CGFloat, ascent: CGFloat),
                               to height: CGFloat?) -> (width: CGFloat, height: CGFloat, ascent: CGFloat) {
        guard let height, height > metrics.height else { return metrics }
        return (metrics.width, height, metrics.ascent + ((height - metrics.height) / 2).rounded())
    }

    /// How far a line `width` wide moves right in `room` for the style's
    /// alignment. Only paragraphs and headings outside lists and quotes move.
    static func alignmentOffset(_ block: TranscriptBlock, style: TranscriptStyle, width: CGFloat, room: CGFloat) -> CGFloat {
        guard isAligned(block, style: style) else { return 0 }
        let slack = max(room - width, 0)
        switch style.textAlignment {
        case .leading: return 0
        case .center: return (slack / 2).rounded(.down)
        case .trailing: return slack
        }
    }

    /// Whether the block's lines follow the style's alignment rather than the leading edge.
    static func isAligned(_ block: TranscriptBlock, style: TranscriptStyle) -> Bool {
        guard style.textAlignment != .leading, block.containers.isEmpty else { return false }
        switch block.kind {
        case .paragraph, .heading: return true
        case .code, .rule, .table: return false
        }
    }

    /// The first `count` lines of `original`, for a line limit. With
    /// `ellipsis`, the last of them ends in "…": it is typeset again from the
    /// rest of the block and truncated, or "…" is added when the block ends
    /// there but more text follows it.
    init(_ original: BlockLayout, keepingLines count: Int, ellipsis: Bool) {
        block = original.block
        width = original.width
        style = original.style
        contentLeading = original.contentLeading
        marker = original.marker
        table = original.table
        imageRevision = original.imageRevision
        definedReferences = original.definedReferences
        let count = min(max(count, 1), original.lines.count)
        var kept = original.lines.prefix(count)
        let insets = style.insets(for: block)
        if ellipsis, let last = kept.last {
            _ = kept.removeLast()
            kept.append(Self.withEllipsis(last, block: block, style: style, insets: insets, width: original.width))
        }
        lines = kept
        let bottom = kept.last.map { $0.frame.maxY } ?? 0
        height = bottom + insets.vertical
        length = kept.last?.range.upperBound ?? 0
        attachments = original.attachments.filter { $0.rect.minY < bottom }
    }

    private static func withEllipsis(_ line: Line, block: TranscriptBlock, style: TranscriptStyle,
                                     insets: TranscriptStyle.Insets, width: CGFloat) -> Line {
        let available = max(width - insets.leading - insets.trailing, 1)
        let rest = NSMutableAttributedString(attributedString: style.attributedString(for: block, range: line.range.lowerBound..<block.utf16Count))
        let attributes = rest.length > 0 ? rest.attributes(at: rest.length - 1, effectiveRange: nil) : style.attributes(for: block.kind)
        // Trailing line breaks would end the line before the ellipsis.
        while rest.length > 0, (rest.string as NSString).character(at: rest.length - 1) == 0x0A {
            rest.deleteCharacters(in: NSRange(location: rest.length - 1, length: 1))
        }
        if line.range.upperBound >= block.utf16Count {
            rest.append(NSAttributedString(string: "…", attributes: attributes))
        }
        let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
        let full = CTLineCreateWithAttributedString(rest)
        let aligned = isAligned(block, style: style)
        let start = aligned ? insets.leading : line.frame.minX
        let room = max(insets.leading + available - start, 1)
        let ctLine = CTLineCreateTruncatedLine(full, Double(room), .end, token) ?? full
        let font = style.font(for: block.kind)
        let metrics = lineMetrics(ctLine, isEmpty: false, font: font)
        let x = aligned ? insets.leading + alignmentOffset(block, style: style, width: metrics.width, room: available) : start
        return Line(ctLine: ctLine, indexBase: line.range.lowerBound, range: line.range,
                    frame: CGRect(x: x, y: line.frame.minY, width: metrics.width, height: line.frame.height),
                    baseline: line.baseline, decorations: nil)
    }

    private static func lineMetrics(_ ctLine: CTLine, isEmpty: Bool, font: CTFont) -> (width: CGFloat, height: CGFloat, ascent: CGFloat) {
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        var lineWidth = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading))
        lineWidth -= CGFloat(CTLineGetTrailingWhitespaceWidth(ctLine))
        if isEmpty {
            ascent = CTFontGetAscent(font)
            descent = CTFontGetDescent(font)
            leading = CTFontGetLeading(font)
            lineWidth = 0
        }
        return (max(lineWidth, 0), ceil(ascent + descent + leading), ascent)
    }

    // MARK: Tables

    /// Columns get the width their widest cell wants. If the table does not
    /// fit, it is laid out as browsers lay out tables: every column gets at
    /// least its longest word, and the space left over goes to the columns
    /// in proportion to how much more they want, so a long cell does not
    /// squeeze a short column until its words break. Only if even the
    /// longest words do not fit are they broken.
    ///
    /// While a table streams, rows that are complete in `previous` are
    /// neither measured nor typeset again, and keep their lines if the
    /// columns did not change, so only the row being written is redrawn.
    private static func layOutTable(_ model: TranscriptTable, block: TranscriptBlock, style: TranscriptStyle, x: CGFloat,
                                    available: CGFloat, blockWidth: CGFloat, images: TranscriptImageStore?, definitions: [String: String],
                                    reusing previous: BlockLayout?) -> (lines: SharedList<Line>, height: CGFloat, table: Table) {
        let columns = max(model.columnCount, 1)
        let padding = style.tableCellPadding
        let verticalPadding = (padding * 0.75).rounded()
        let font = style.font(for: block.kind)
        let fixedHeight = style.lineHeight(for: block.kind)
        let gap = fixedHeight == nil ? style.lineSpacing : 0
        let decorated = DecoratedTags(block)
        let sizing = ImageSizing(store: images, maximumWidth: max(available / CGFloat(columns) - padding * 2, 20))
        let minimumWidth = padding * 2 + style.effectiveBodySize

        // Leading rows that are complete in the previous layout and unchanged.
        var kept = 0
        var old: Table?
        if let previous, let oldTable = previous.table, let oldModel = previous.block.kind.table,
           oldModel.alignments == model.alignments, previous.block.isStyledPrefix(of: block) {
            let limit = min(oldModel.rows.count - 1, model.rows.count)
            while kept < limit, oldModel.rows[kept] == model.rows[kept] { kept += 1 }
            old = oldTable
        }

        typealias Cell = (text: NSAttributedString, typesetter: CTTypesetter, range: Range<Int>)
        func makeCells(_ row: Int) -> [Cell] {
            model.rows[row].prefix(columns).map { range in
                let text = style.attributedString(for: block, range: range, extraTraits: row == 0 ? .bold : [], images: sizing,
                                                  definitions: definitions, kerns: decorated?.kerns ?? [:])
                return (text, CTTypesetterCreateWithAttributedString(text), range)
            }
        }
        /// Each cell's width on one line and the width of its longest word,
        /// both from the same unwrapped lines.
        func measure(_ cells: [Cell]) -> (natural: [CGFloat], minimum: [CGFloat]) {
            var natural: [CGFloat] = []
            var minimum: [CGFloat] = []
            for cell in cells {
                let string = cell.text.string as NSString
                var widest: CGFloat = 0
                var longestWord: CGFloat = 0
                var start = 0
                while start < cell.text.length {
                    let count = max(CTTypesetterSuggestLineBreak(cell.typesetter, start, 100_000), 1)
                    let line = CTTypesetterCreateLine(cell.typesetter, CFRange(location: start, length: count))
                    widest = max(widest, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) - CGFloat(CTLineGetTrailingWhitespaceWidth(line)))
                    var wordStart = start
                    for index in start...(start + count) {
                        let isBreak = index == start + count || [0x20, 0x09, 0x0A].contains(string.character(at: index))
                        guard isBreak else { continue }
                        if index > wordStart {
                            let width = CTLineGetOffsetForStringIndex(line, index, nil) - CTLineGetOffsetForStringIndex(line, wordStart, nil)
                            longestWord = max(longestWord, width)
                        }
                        wordStart = index + 1
                    }
                    start += count
                }
                natural.append(ceil(widest) + padding * 2)
                minimum.append(ceil(longestWord) + padding * 2)
            }
            return (natural, minimum)
        }

        var cells = [[Cell]?](repeating: nil, count: model.rows.count)
        var rowNaturals: [[CGFloat]] = []
        var rowMinimums: [[CGFloat]] = []
        for row in model.rows.indices {
            if row < kept, let old {
                rowNaturals.append(old.naturalWidths[row])
                rowMinimums.append(old.minimumWidths[row])
            } else {
                let made = makeCells(row)
                cells[row] = made
                let measured = measure(made)
                rowNaturals.append(measured.natural)
                rowMinimums.append(measured.minimum)
            }
        }
        var natural = [CGFloat](repeating: minimumWidth, count: columns)
        var minimum = [CGFloat](repeating: minimumWidth, count: columns)
        for (naturals, minimums) in zip(rowNaturals, rowMinimums) {
            for (column, width) in naturals.enumerated() where column < columns { natural[column] = max(natural[column], width) }
            for (column, width) in minimums.enumerated() where column < columns { minimum[column] = max(minimum[column], width) }
        }

        var widths = natural
        let wanted = natural.reduce(0, +)
        if wanted > available {
            let least = minimum.reduce(0, +)
            if least >= available {
                // Even the longest words do not fit: they break.
                widths = minimum.map { floor(available * $0 / least) }
            } else {
                let spare = available - least
                let stretch = wanted - least
                widths = (0..<columns).map { column in
                    floor(minimum[column] + spare * (natural[column] - minimum[column]) / stretch)
                }
            }
        }
        var columnX = [x]
        for width in widths { columnX.append(columnX[columnX.count - 1] + width) }

        var lines = SharedList<Line>()
        var rowY: [CGFloat] = [0]
        var cellLines: [[Range<Int>]] = []
        var firstRow = 0
        if kept > 0, let old, let previous, old.columnX == columnX {
            // Same columns: the kept rows look exactly as before.
            lines = previous.lines.prefix(old.cellLines[kept - 1].last?.upperBound ?? 0)
            rowY = Array(old.rowY[...kept])
            cellLines = Array(old.cellLines[..<kept])
            firstRow = kept
        }
        for row in firstRow..<model.rows.count {
            let rowCells = cells[row] ?? makeCells(row)
            let top = rowY[rowY.count - 1]
            var bottom = top + verticalPadding * 2 + ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
            var rowLines: [Range<Int>] = []
            for (column, cell) in rowCells.enumerated() {
                let first = lines.count
                let textWidth = max(widths[column] - padding * 2, 1)
                var y = top + verticalPadding
                func add(_ ctLine: CTLine, range: Range<Int>) {
                    let metrics = fitted(lineMetrics(ctLine, isEmpty: range.isEmpty, font: font), to: fixedHeight)
                    let slack = max(textWidth - metrics.width, 0)
                    let offset: CGFloat
                    switch column < model.alignments.count ? model.alignments[column] : .leading {
                    case .leading: offset = 0
                    case .center: offset = (slack / 2).rounded()
                    case .trailing: offset = slack
                    }
                    var decorations: LineDecorations?
                    if let decorated {
                        // A tag at the start of a cell gets no room on its left: it
                        // reaches into the cell's padding instead.
                        decorations = LineDecorations.make(line: ctLine, range: range, indexBase: cell.range.lowerBound,
                                                           visibleWidth: metrics.width, top: -metrics.ascent,
                                                           bottom: metrics.height - metrics.ascent,
                                                           lineX: columnX[column] + padding + offset, blockWidth: blockWidth,
                                                           block: block.id, tags: decorated, text: cell.text,
                                                           textBase: cell.range.lowerBound)
                    }
                    lines.append(Line(
                        ctLine: ctLine, indexBase: cell.range.lowerBound, range: range,
                        frame: CGRect(x: columnX[column] + padding + offset, y: y, width: metrics.width, height: metrics.height),
                        baseline: y + metrics.ascent,
                        decorations: decorations
                    ))
                    y += metrics.height + gap
                }
                var start = 0
                while start < cell.text.length {
                    var count = max(CTTypesetterSuggestLineBreak(cell.typesetter, start, Double(textWidth)), 1)
                    if let decorated, start + count < cell.text.length {
                        let base = cell.range.lowerBound
                        count = decorated.lineEnd(from: base + start, to: base + start + count) { range in
                            CTTypesetterSuggestLineBreak(cell.typesetter, range.lowerBound - base, Double(textWidth)) >= range.count
                        } - base - start
                    }
                    let ctLine = CTTypesetterCreateLine(cell.typesetter, CFRange(location: start, length: count))
                    add(ctLine, range: (cell.range.lowerBound + start)..<(cell.range.lowerBound + start + count))
                    start += count
                }
                if cell.text.length == 0 {
                    // An empty cell still has a place for the caret.
                    let empty = CTLineCreateWithAttributedString(NSAttributedString(string: "", attributes: style.attributes(for: block.kind)))
                    add(empty, range: cell.range.lowerBound..<cell.range.lowerBound)
                }
                bottom = max(bottom, y - gap + verticalPadding)
                rowLines.append(first..<lines.count)
            }
            rowY.append(ceil(bottom))
            cellLines.append(rowLines)
        }
        let table = Table(columnX: columnX, rowY: rowY, cellLines: cellLines, naturalWidths: rowNaturals, minimumWidths: rowMinimums)
        return (lines, rowY[rowY.count - 1], table)
    }

    // MARK: Markers and images

    private static func makeMarker(for block: TranscriptBlock, style: TranscriptStyle, firstLine: Line?) -> Marker? {
        guard let kind = block.marker, let firstLine, let item = block.containers.lastIndex(of: .listItem) else { return nil }
        // The marker sits in the gutter of the innermost list item.
        let gutterEnd = style.contentLeading(for: Array(block.containers[...item]))
        let font = style.font(for: .paragraph)
        switch kind {
        case .task(let checked):
            let side = (style.effectiveBodySize * 0.82).rounded()
            let middle = firstLine.baseline - CTFontGetCapHeight(font) / 2
            return .checkbox(CGRect(x: gutterEnd - side - 6, y: (middle - side / 2).rounded(), width: side, height: side), checked: checked)
        case .bullet, .number:
            let text: String
            if case .number(let number) = kind {
                text = number
            } else {
                let depth = block.listLevel
                text = depth <= 1 ? "•" : (depth == 2 ? "◦" : "▪")
            }
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: style.attributes(for: .paragraph)))
            let markerWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            return .text(line, origin: CGPoint(x: max(gutterEnd - markerWidth - 7, 0), y: firstLine.baseline))
        }
    }

    private static func findAttachments(in lines: SharedList<Line>) -> [Attachment] {
        var result: [Attachment] = []
        for line in lines {
            for run in CTLineGetGlyphRuns(line.ctLine) as! [CTRun] {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                guard let attachment = attributes[TranscriptStyle.imageKey.rawValue] as? ImageAttachment else { continue }
                var position = CGPoint.zero
                CTRunGetPositions(run, CFRange(location: 0, length: 1), &position)
                let rect = CGRect(x: line.frame.minX + position.x, y: line.baseline - attachment.ascent,
                                  width: attachment.size.width, height: attachment.size.height)
                result.append(Attachment(attachment: attachment, rect: rect))
            }
        }
        return result
    }

    // MARK: Offsets and geometry

    /// The line an offset belongs to. An offset on a wrap boundary belongs to the later line.
    func lineIndex(forOffset offset: Int) -> Int {
        var low = 0
        var high = lines.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lines[mid].range.lowerBound <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    private func x(forOffset offset: Int, in line: Line) -> CGFloat {
        guard !line.range.isEmpty else { return line.frame.minX }
        let clamped = min(max(offset, line.range.lowerBound), line.range.upperBound)
        return line.frame.minX + CTLineGetOffsetForStringIndex(line.ctLine, clamped - line.indexBase, nil)
    }

    func caretRect(atOffset offset: Int) -> CGRect {
        let line = lines[lineIndex(forOffset: offset)]
        return CGRect(x: x(forOffset: offset, in: line) - 1, y: line.frame.minY, width: 2, height: line.frame.height)
    }

    func closestOffset(to point: CGPoint) -> Int {
        guard let table else { return closestOffset(to: point, amongLines: 0..<lines.count) }
        // The cell under the point, or the nearest one.
        let row = min(max((table.rowY.lastIndex { $0 <= point.y } ?? 0), 0), table.cellLines.count - 1)
        guard row >= 0, !table.cellLines[row].isEmpty else { return 0 }
        let column = min(max((table.columnX.lastIndex { $0 <= point.x } ?? 0), 0), table.cellLines[row].count - 1)
        return closestOffset(to: point, amongLines: table.cellLines[row][column])
    }

    private func closestOffset(to point: CGPoint, amongLines indexes: Range<Int>) -> Int {
        guard !indexes.isEmpty else { return 0 }
        let index = indexes.first { point.y < lines[$0].frame.maxY } ?? indexes.upperBound - 1
        let line = lines[index]
        guard !line.range.isEmpty else { return line.range.lowerBound }

        let localHit = CTLineGetStringIndexForPosition(line.ctLine, CGPoint(x: point.x - line.frame.minX, y: 0))
        guard localHit != kCFNotFound else { return line.range.lowerBound }
        let hit = localHit + line.indexBase
        // The offset at the end of a non-final line is the start of the next
        // line (or sits after its newline), so stop one short of it.
        let isLastLine = index == indexes.upperBound - 1
        let upper = isLastLine ? line.range.upperBound : line.range.upperBound - 1
        return min(max(hit, line.range.lowerBound), max(upper, line.range.lowerBound))
    }

    /// The offset of the character drawn under `point`, or nil if the point
    /// is not on a glyph (in a margin, or past the end of a line).
    func characterOffset(at point: CGPoint) -> Int? {
        guard let line = lines.first(where: { $0.frame.minY <= point.y && point.y < $0.frame.maxY
                                               && point.x >= $0.frame.minX && point.x < $0.frame.maxX }),
              !line.range.isEmpty else { return nil }
        let localBoundary = CTLineGetStringIndexForPosition(line.ctLine, CGPoint(x: point.x - line.frame.minX, y: 0))
        guard localBoundary != kCFNotFound else { return nil }
        let boundary = localBoundary + line.indexBase
        // `boundary` is the nearest caret position; the character under the
        // point starts at it or just before it.
        let offset = x(forOffset: boundary, in: line) > point.x ? boundary - 1 : boundary
        return line.range.contains(offset) ? offset : nil
    }

    /// The link of a padded tag whose box is under `point`: its padding
    /// belongs to the characters around it, so `characterOffset` misses it.
    func decorationLink(at point: CGPoint) -> String? {
        for line in lines where line.decorations?.links.isEmpty == false
            && line.frame.minY <= point.y && point.y < line.frame.maxY {
            let local = CGPoint(x: point.x - line.frame.minX, y: point.y - line.baseline)
            if let hit = line.decorations?.links.first(where: { $0.rect.minX <= local.x && local.x < $0.rect.maxX }) { return hit.link }
        }
        return nil
    }

    /// One rect per line touched by `range`. Left-to-right only for now.
    func selectionRects(for range: Range<Int>) -> [CGRect] {
        guard !range.isEmpty else { return [] }
        var rects: [CGRect] = []
        let first = lineIndex(forOffset: range.lowerBound)
        for index in first..<lines.count {
            let line = lines[index]
            if line.range.lowerBound >= range.upperBound { break }
            let startX = x(forOffset: max(range.lowerBound, line.range.lowerBound), in: line)
            let continuesPastLine = range.upperBound >= line.range.upperBound && index < lines.count - 1
            let endX = continuesPastLine ? max(line.frame.maxX, startX) : x(forOffset: range.upperBound, in: line)
            if endX > startX || continuesPastLine {
                rects.append(CGRect(x: startX, y: line.frame.minY, width: max(endX - startX, 4), height: line.frame.height))
            }
        }
        return rects
    }
}
