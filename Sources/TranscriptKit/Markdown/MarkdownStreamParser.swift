import Foundation

/// Parses Markdown that arrives in chunks into a `TranscriptDocument`.
///
/// The work done by an `append` depends on the size of the chunk, not on how
/// much came before it:
///
/// - Each complete line goes through the block parser once.
/// - Every block except the last is frozen as soon as a later block begins:
///   it is parsed one final time and never touched again.
/// - The last block's inline Markdown is parsed from a checkpoint, where the
///   previous parse stopped being certain, rather than from its start.
///
/// While streaming, the last block is parsed speculatively (see
/// `InlineParser` and `BlockParser`) so that its displayed text only ever
/// grows at the end. Call `finish()` when the stream ends to show anything
/// that was being held back.
public struct MarkdownStreamParser: Sendable {
    public private(set) var document = TranscriptDocument()

    private var frozen = SharedList<TranscriptBlock>()
    /// Sum of the frozen blocks' UTF-16 lengths.
    private var frozenLength = 0
    /// Blocks not frozen yet, after every complete line so far.
    private var state: BlockParser.State
    /// The unterminated last line.
    private var partial = ""
    /// `partial` as UTF-16, extended chunk by chunk.
    private var partialUnits: [UInt16] = []
    /// Inline progress on a block that so far exists only because of the
    /// partial line, kept for when the line is complete.
    private var pendingCheckpoint: (index: Int, kind: BlockParser.Kind, checkpoint: InlineParser.Checkpoint)?
    private let idPrefix: String
    private let tags: [String: TranscriptTag]

    /// - Parameters:
    ///   - idPrefix: prefix for block ids, which are `prefix-index`. Use
    ///     distinct prefixes if several parsers feed one document.
    ///   - tags: custom tags the text may use, and how they look; see
    ///     `TranscriptTag`. Other tags show as written.
    ///   - newlinesAsLineBreaks: if true, a single newline inside a paragraph
    ///     or a heading is a line break, as models often intend. A line that
    ///     ends in a backslash or two spaces still gives one line break, not
    ///     two. If false (the default), the newline is a space, as in CommonMark.
    public init(idPrefix: String = String(UUID().uuidString.prefix(8)), tags: [TranscriptTag] = [],
                newlinesAsLineBreaks: Bool = false) {
        self.idPrefix = idPrefix
        self.tags = TranscriptTag.byName(tags)
        state = BlockParser.State(newlinesAsLineBreaks: newlinesAsLineBreaks)
    }

    /// Adds the next piece of the stream. Chunks can split anywhere.
    public mutating func append(_ chunk: String) {
        var text = Substring(chunk)
        if text.utf8.contains(UInt8(ascii: "\r")) { text = Substring(text.replacingOccurrences(of: "\r", with: "")) }
        if let lastNewline = text.lastIndex(of: "\n") {
            let complete = partial + text[..<lastNewline]
            partial = String(text[text.index(after: lastNewline)...])
            partialUnits = BlockParser.utf16(partial)
            for line in complete.split(separator: "\n", omittingEmptySubsequences: false) {
                process(String(line))
            }
        } else {
            partial += text
            partialUnits += BlockParser.utf16(text)
        }
        rebuild(final: false)
    }

    /// Marks the end of the stream: nothing is held back any more and unclosed
    /// markup is shown literally. More text can still be appended afterwards.
    public mutating func finish() {
        rebuild(final: true)
    }

    /// Parses a complete Markdown string, with the custom `tags` it may use.
    /// `newlinesAsLineBreaks` is as in `init`.
    public static func document(from markdown: String, idPrefix: String = "md", tags: [TranscriptTag] = [],
                                newlinesAsLineBreaks: Bool = false) -> TranscriptDocument {
        var parser = MarkdownStreamParser(idPrefix: idPrefix, tags: tags, newlinesAsLineBreaks: newlinesAsLineBreaks)
        parser.append(markdown)
        parser.finish()
        return parser.document
    }

    private mutating func process(_ line: String) {
        let countBefore = state.blocks.count
        state.process(line)
        if let pending = pendingCheckpoint, state.blocks.count > countBefore {
            let local = pending.index - frozen.count
            if local == state.blocks.count - 1, state.blocks[local].kind == pending.kind {
                // The line that was partial when this block was first shown.
                state.blocks[local].checkpoint = pending.checkpoint
            }
            pendingCheckpoint = nil
        }
        // A block is final once a later one has begun.
        while state.blocks.count > 1 {
            var raw = state.blocks.removeFirst()
            let block = makeBlock(&raw, index: frozen.count, open: false, completeRows: raw.rows.count)
            frozenLength += block.utf16Count
            frozen.append(block)
        }
    }

    private mutating func rebuild(final: Bool) {
        // The partial line is parsed on a copy: it may still be held back,
        // and it is parsed again for real once its newline arrives.
        var speculative = state
        if !partial.isEmpty, final || !speculative.shouldHoldBack(partial) {
            speculative.process(partial, lineUnits: partialUnits)
            // A block the partial line started is made afresh on every
            // update; its inline parse resumes from where the last update's
            // got to, or a long first line would be parsed whole every time.
            if !final, let pending = pendingCheckpoint, speculative.blocks.count > state.blocks.count {
                let local = pending.index - frozen.count
                if local == state.blocks.count, speculative.blocks[local].kind == pending.kind {
                    speculative.blocks[local].checkpoint = pending.checkpoint
                }
            }
        }

        var open: [TranscriptBlock] = []
        open.reserveCapacity(speculative.blocks.count)
        // A line that may be a table header waits for the line below it.
        let shown = !final && speculative.hidesLastBlock ? speculative.blocks.count - 1 : speculative.blocks.count
        for index in 0..<shown {
            let isLast = index == speculative.blocks.count - 1
            // Table rows from complete lines are final; one from the partial line is not.
            let completeRows = index < state.blocks.count ? state.blocks[index].rows.count : 0
            open.append(makeBlock(&speculative.blocks[index], index: frozen.count + index, open: !final && isLast,
                                  completeRows: final ? speculative.blocks[index].rows.count : completeRows))
        }

        // Keep the inline progress made on the copy. A partial line that is
        // not held back is classified the same way once complete, so it is
        // valid for the real parse. `finish()` also parses held-back lines,
        // which may yet turn out differently, so it keeps nothing.
        if !final {
            for index in state.blocks.indices where index < speculative.blocks.count {
                state.blocks[index].checkpoint = speculative.blocks[index].checkpoint
                state.blocks[index].parsedRows = speculative.blocks[index].parsedRows
            }
            if speculative.blocks.count > state.blocks.count {
                let index = state.blocks.count
                pendingCheckpoint = (frozen.count + index, speculative.blocks[index].kind, speculative.blocks[index].checkpoint)
            } else {
                pendingCheckpoint = nil
            }
        }

        // `frozen` is handed over as is: every version of the document shares
        // its storage, and freezing a block appends to it without copying.
        document = TranscriptDocument(settled: frozen, open: open, settledLength: frozenLength,
                                      linkDefinitions: speculative.definitions)
    }

    /// - Parameter completeRows: for tables, how many rows come from complete
    ///   lines; a row after them is still being written.
    private func makeBlock(_ raw: inout BlockParser.RawBlock, index: Int, open: Bool, completeRows: Int) -> TranscriptBlock {
        let id = "\(idPrefix)-\(index)"
        let kind: TranscriptBlock.Kind
        switch raw.kind {
        case .code(let language, _, _, _, _):
            return TranscriptBlock(id: id, kind: .code(language: language), text: raw.code,
                                   containers: raw.containers, marker: raw.marker)
        case .rule:
            return TranscriptBlock(id: id, kind: .rule, text: "", containers: raw.containers, marker: raw.marker)
        case .table(let alignments):
            return makeTable(&raw, id: id, alignments: alignments, open: open, completeRows: completeRows)
        case .math(let closer, let closed):
            let source = raw.mathLines.joined(separator: "\n")
            let tex = closed ? source.dropFirst(2).dropLast(closer.count).trimmingCharacters(in: .whitespacesAndNewlines) : ""
            if !tex.isEmpty {
                return TranscriptBlock(id: id, kind: .paragraph, text: "\u{FFFC}",
                                       spans: [InlineSpan(range: 0..<1, math: TranscriptMath(tex: tex, isDisplay: true))],
                                       containers: raw.containers, marker: raw.marker)
            }
            // Not a formula: empty, or never closed. Its lines show as written.
            var paragraph = raw
            paragraph.becomeParagraph()
            let text = paragraph.inlineSource()
            let result = InlineParser.parse(text.units, open: false, stableLength: text.units.count,
                                            resumingFrom: &paragraph.checkpoint, tags: tags)
            return TranscriptBlock(id: id, kind: .paragraph, text: result.text, spans: result.spans,
                                   containers: raw.containers, marker: raw.marker)
        case .heading(let level):
            kind = .heading(level: level)
        case .paragraph:
            kind = .paragraph
        }
        let source = raw.inlineSource()
        let result = InlineParser.parse(source.units, open: open, stableLength: source.stableLength, resumingFrom: &raw.checkpoint,
                                        tags: tags)
        return TranscriptBlock(id: id, kind: kind, text: result.text, spans: result.spans,
                               containers: raw.containers, marker: raw.marker)
    }

    /// A table's text is its cells joined by tabs, rows by newlines. Complete
    /// rows are padded or cut to the column count; a row still being written
    /// shows only the cells it has so far, so its text only grows.
    private func makeTable(_ raw: inout BlockParser.RawBlock, id: String, alignments: [TranscriptTable.Alignment],
                           open: Bool, completeRows: Int) -> TranscriptBlock {
        let columns = alignments.count
        var text: [UInt16] = []
        var spans: [InlineSpan] = []
        var rows: [[Range<Int>]] = []
        rows.reserveCapacity(raw.rows.count)
        for (rowIndex, sourceRow) in raw.rows.enumerated() {
            let isComplete = rowIndex < completeRows
            let cells: [InlineParser.Result]
            if isComplete, rowIndex < raw.parsedRows.count {
                cells = raw.parsedRows[rowIndex]
            } else {
                let count = isComplete ? columns : min(sourceRow.count, columns)
                cells = (0..<count).map { column in
                    let source = column < sourceRow.count ? sourceRow[column] : ""
                    // Only the cell being written is parsed as open.
                    return InlineParser.parse(source, open: open && !isComplete && column == count - 1, tags: tags)
                }
                if isComplete, rowIndex == raw.parsedRows.count { raw.parsedRows.append(cells) }
            }
            if rowIndex > 0 { text.append(0x0A) }
            var ranges: [Range<Int>] = []
            ranges.reserveCapacity(cells.count)
            for (column, cell) in cells.enumerated() {
                if column > 0 { text.append(0x09) }
                let start = text.count
                text.append(contentsOf: cell.text.utf16)
                ranges.append(start..<text.count)
                for span in cell.spans {
                    var shifted = span
                    shifted.range = (span.range.lowerBound + start)..<(span.range.upperBound + start)
                    spans.append(shifted)
                }
            }
            rows.append(ranges)
        }
        let table = TranscriptTable(alignments: alignments, rows: rows)
        return TranscriptBlock(id: id, kind: .table(table), text: String(decoding: text, as: UTF16.self), spans: spans,
                               containers: raw.containers, marker: raw.marker)
    }
}
