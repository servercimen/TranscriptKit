import Foundation

/// Splits Markdown source lines into blocks, one line at a time.
///
/// Follows CommonMark's two-level structure: container blocks (block quotes
/// and list items, nested in any order) hold leaf blocks (paragraphs, ATX and
/// setext headings, fenced and indented code, GFM tables, thematic breaks).
/// Each leaf becomes one block that records the containers it sits in.
/// HTML comment blocks are dropped. Not supported: other raw HTML blocks
/// (they read as paragraphs) and link reference definitions.
enum BlockParser {
    enum Kind: Equatable {
        case paragraph
        case heading(level: Int)
        /// `fence` is nil for an indented code block.
        case code(language: String?, fence: Character?, fenceLength: Int, indent: Int, closed: Bool)
        case rule
        case table(alignments: [TranscriptTable.Alignment])
    }

    /// A block's content, kept in the form that is cheapest to extend.
    struct RawBlock {
        var kind: Kind
        let containers: [TranscriptBlock.Container]
        let marker: TranscriptBlock.ListMarker?
        /// Code blocks: the lines so far, joined by "\n".
        private(set) var code = ""
        private(set) var lineCount = 0
        /// Indented code: blank lines that only count if more code follows.
        private var pendingBlankLines = 0
        /// Paragraphs and headings: the inline source of every line but the
        /// last, each followed by its line break.
        private var committedSource: [UInt16] = []
        /// Paragraphs and headings: the last line so far. What it contributes
        /// depends on whether another line follows it.
        private(set) var lastLine: String?
        /// `lastLine` trimmed, as UTF-16: converted once when the line is
        /// added, not again on every update while it stays the last line.
        private var lastLineUnits: [UInt16] = []
        /// Tables: each row's cells, as source.
        private(set) var rows: [[String]] = []
        /// Tables: the parsed cells of complete rows, filled in as they are parsed.
        var parsedRows: [[InlineParser.Result]] = []
        /// Where inline parsing of this block can resume.
        var checkpoint = InlineParser.Checkpoint()

        init(kind: Kind, containers: [TranscriptBlock.Container], marker: TranscriptBlock.ListMarker?) {
            self.kind = kind
            self.containers = containers
            self.marker = marker
        }

        /// - Parameter units: `line` trimmed, as UTF-16, if the caller has it.
        mutating func addLine(_ line: String, units: [UInt16]? = nil) {
            switch kind {
            case .code(_, let fence, _, _, _):
                if fence == nil, line.isEmpty {
                    // Kept only if the indented block continues after it.
                    pendingBlankLines += 1
                    return
                }
                for _ in 0..<pendingBlankLines {
                    if lineCount > 0 { code += "\n" }
                    lineCount += 1
                }
                pendingBlankLines = 0
                if lineCount > 0 { code += "\n" }
                code += line
                lineCount += 1
            case .rule:
                break
            case .table:
                rows.append(BlockParser.tableCells(line))
                lineCount += 1
            case .paragraph, .heading:
                if let lastLine {
                    committedSource += BlockParser.contributionWhenFollowed(lastLineUnits, of: lastLine)
                }
                lastLine = line
                lastLineUnits = units ?? BlockParser.utf16(BlockParser.trimmingSpaceAndTab(Substring(line)))
                lineCount += 1
            }
        }

        /// Turns a one-line paragraph into a table with that line as its header.
        mutating func becomeTable(alignments: [TranscriptTable.Alignment]) {
            let header = lastLine ?? ""
            kind = .table(alignments: alignments)
            committedSource = []
            lastLine = nil
            lastLineUnits = []
            rows = [BlockParser.tableCells(header)]
            lineCount = 1
            checkpoint = InlineParser.Checkpoint()
        }

        /// The block's inline source, and how many of its leading units no
        /// later line can change.
        func inlineSource() -> (units: [UInt16], stableLength: Int) {
            guard lastLine != nil else { return (committedSource, committedSource.count) }
            let tail = lastLineUnits
            // Trailing backslashes, and the spaces before them, are dropped
            // if another line follows (a backslash hard break). Everything
            // else only ever has text added after it.
            var stable = tail.count
            while stable > 0, BlockParser.isBreakSensitive(tail[stable - 1]) { stable -= 1 }
            return (committedSource + tail, committedSource.count + stable)
        }

        /// A one-line paragraph that a delimiter row on the next line would
        /// make a table header.
        var couldBecomeTable: Bool {
            guard kind == .paragraph, lineCount == 1, let lastLine else { return false }
            return lastLine.utf8.contains(UInt8(ascii: "|"))
        }

        /// A possible table header that starts with "|", as models write
        /// them: it is not shown until the next line says what it is, so a
        /// table does not first flash as a line of pipes.
        var isHiddenWhileOpen: Bool {
            // Starting with "|" means containing one: no need to search the line.
            kind == .paragraph && lineCount == 1 && lastLine?.hasPrefix("|") == true
        }
    }

    /// An open block quote or list item.
    private struct OpenContainer {
        let kind: TranscriptBlock.Container
        /// List items: columns of indentation, counted from where the
        /// item's line starts, that continue the item.
        let contentIndent: Int
        /// List items: the marker, until the item's first block takes it.
        var pendingMarker: TranscriptBlock.ListMarker?
    }

    /// The parser between lines. Feed it complete lines with `process`; it
    /// keeps only the blocks the caller has not taken yet.
    struct State {
        /// The last block may still grow; the caller takes the others.
        var blocks: [RawBlock] = []
        private var containers: [OpenContainer] = []
        /// The last block is a paragraph with no blank line since.
        private var canContinue = false
        /// The last block is a table that further rows can join.
        private var tableOpen = false
        /// Inside an HTML comment block, which is not shown.
        private var inComment = false
        /// Link reference definitions so far, by normalised label.
        private(set) var definitions: [String: String] = [:]
        /// The list at each container depth that a new item there would
        /// continue, so items are numbered as CommonMark numbers them: from
        /// the first item's number, one up per item.
        private var lists: [ListCounter?] = []

        private struct ListCounter {
            /// The bullet ("-", "+", "*") or the ordered delimiter ("." or ")").
            let character: Character
            let isOrdered: Bool
            /// The number the next item gets, for an ordered list.
            let next: Int
        }

        /// Lists at `depth` and deeper end: a block other than a list item
        /// started there.
        private mutating func endLists(from depth: Int) {
            if lists.count > depth { lists.removeSubrange(depth...) }
        }

        private var lastBlockIsOpenFence: Bool {
            guard case .code(_, .some, _, _, false)? = blocks.last?.kind else { return false }
            return true
        }

        private var lastBlockIsOpenIndentedCode: Bool {
            guard case .code(_, nil, _, _, false)? = blocks.last?.kind else { return false }
            return true
        }

        /// Nothing more joins the last block: its containers have closed,
        /// or a line that is not part of it came between.
        private mutating func endLastBlock() {
            canContinue = false
            tableOpen = false
            guard let last = blocks.indices.last,
                  case .code(let language, let fence, let length, let indent, false) = blocks[last].kind else { return }
            blocks[last].kind = .code(language: language, fence: fence, fenceLength: length, indent: indent, closed: true)
        }

        private mutating func start(_ kind: Kind, line: String? = nil, units: [UInt16]? = nil) {
            // The innermost list item's first block carries its marker.
            var marker: TranscriptBlock.ListMarker?
            if let index = containers.lastIndex(where: { $0.kind == .listItem }), containers[index].pendingMarker != nil {
                marker = containers[index].pendingMarker
                containers[index].pendingMarker = nil
            }
            var block = RawBlock(kind: kind, containers: containers.map(\.kind), marker: marker)
            if let line { block.addLine(line, units: units) }
            blocks.append(block)
            endLists(from: containers.count)
            canContinue = false
            tableOpen = false
        }

        /// - Parameter lineUnits: the whole line as UTF-16, if the caller
        ///   has it: the line being written, which the stream parser converts
        ///   a chunk at a time rather than whole on every update.
        mutating func process(_ line: String, lineUnits: [UInt16]? = nil) {
            var scanner = LineScanner(line)
            /// The UTF-16 of `part`, a trimmed piece of the line, cut from
            /// `lineUnits`. What precedes a paragraph's text on its line
            /// (indentation, quote and list markers) and the whitespace
            /// trimmed after it are ASCII, so byte offsets are unit offsets.
            func units(of part: Substring, sliceOfLine: Bool) -> [UInt16]? {
                guard let lineUnits, sliceOfLine else { return nil }
                let start = line.utf8.distance(from: line.startIndex, to: part.startIndex)
                let end = lineUnits.count - line.utf8.distance(from: part.endIndex, to: line.endIndex)
                guard start >= 0, start <= end, end <= lineUnits.count else { return nil }
                let cut = Array(lineUnits[start..<end])
                assert(!InlineParser.checksSettledResult || cut == BlockParser.utf16(part), "The line's UTF-16 does not match the line")
                return cut
            }

            // 1. Which open containers does this line continue?
            var matched = 0
            for container in containers {
                switch container.kind {
                case .quote:
                    guard scanner.consumeQuoteMarker() else { break }
                    matched += 1
                    continue
                case .listItem:
                    if scanner.restIsBlank {
                        // A blank line stays in the item, minus the item's indentation.
                        scanner.consumeColumns(min(scanner.indentWidth, container.contentIndent))
                        matched += 1
                        continue
                    }
                    guard scanner.indentWidth >= container.contentIndent else { break }
                    scanner.consumeColumns(container.contentIndent)
                    matched += 1
                    continue
                }
                break
            }
            let allMatched = matched == containers.count

            // 2. An open fence takes every line of its containers verbatim.
            if lastBlockIsOpenFence, allMatched,
               case .code(let language, let fence?, let length, let indent, _) = blocks[blocks.count - 1].kind {
                let rest = scanner.rest
                if BlockParser.isClosingFence(rest, character: fence, length: length) {
                    blocks[blocks.count - 1].kind = .code(language: language, fence: fence, fenceLength: length, indent: indent, closed: true)
                } else {
                    blocks[blocks.count - 1].addLine(BlockParser.dropIndent(rest, upTo: indent))
                }
                return
            }
            if inComment {
                if BlockParser.containsASCII(scanner.rest, "-->") { inComment = false }
                return
            }

            // 3. Indented code continues with indented or blank lines.
            if lastBlockIsOpenIndentedCode, allMatched {
                if scanner.restIsBlank {
                    blocks[blocks.count - 1].addLine("")
                    return
                }
                if scanner.indentWidth >= 4 {
                    scanner.consumeColumns(4)
                    blocks[blocks.count - 1].addLine(String(scanner.rest))
                    return
                }
            }

            let indent = scanner.indentWidth
            let content = BlockParser.trimmingSpaceAndTab(scanner.rest)
            let contentIsSlice = scanner.restIsSliceOfLine

            // 4. A lazy continuation line keeps a paragraph going even
            // without its containers' markers.
            if !allMatched, canContinue, !content.isEmpty, !BlockParser.startsBlock(content, indent: indent) {
                blocks[blocks.count - 1].addLine(String(content), units: units(of: content, sliceOfLine: contentIsSlice))
                return
            }

            // 5. Containers the line did not continue are closed, and so is
            // whatever block was open in them.
            if !allMatched {
                containers.removeLast(containers.count - matched)
                endLastBlock()
            }

            if content.isEmpty {
                // A blank line ends a paragraph or table, not a code block.
                canContinue = false
                tableOpen = false
                return
            }

            // 6. New containers.
            var openedContainers = false
            while true {
                let indent = scanner.indentWidth
                guard indent < 4 else { break }
                var probe = scanner
                probe.consumeIndent()
                let rest = probe.rest
                if rest.hasPrefix(">") {
                    scanner.consumeQuoteMarker()
                    endLists(from: containers.count)
                    containers.append(OpenContainer(kind: .quote, contentIndent: 0, pendingMarker: nil))
                    openedContainers = true
                    endLastBlock()
                    continue
                }
                // A thematic break is not a list item ("- - -", "* * *").
                if BlockParser.isRule(BlockParser.trimmingSpaceAndTab(rest)) { break }
                guard let item = BlockParser.listMarker(rest) else { break }
                // An empty item, or a numbered one not starting at 1, cannot
                // interrupt a paragraph ("foo\n-" is a heading, "in\n2024. it" one paragraph).
                if canContinue, !openedContainers, allMatched, !BlockParser.canInterruptParagraph(item, rest: rest) { break }
                scanner.consumeIndent()
                scanner.consumeCharacters(item.markerLength)
                var spaces = scanner.indentWidth
                if scanner.restIsBlank {
                    spaces = 1
                } else if spaces > 4 {
                    // Indented code inside the item: only one space belongs to the marker.
                    spaces = 1
                }
                scanner.consumeColumns(spaces)
                // The item's number: one more than the item before it in the same list.
                let depth = containers.count
                var marker = item.marker
                let previous = depth < lists.count ? lists[depth] : nil
                let continues = previous.map { $0.character == item.character && $0.isOrdered == (item.number != nil) } ?? false
                var next = 0
                if let written = item.number {
                    let number = continues ? previous!.next : written
                    marker = .number("\(number)\(item.character)")
                    next = number + 1
                }
                endLists(from: depth)
                while lists.count <= depth { lists.append(nil) }
                lists[depth] = ListCounter(character: item.character, isOrdered: item.number != nil, next: next)
                // "[ ] " or "[x] " right after the marker: a task.
                let after = scanner.rest
                if after.hasPrefix("[ ] ") || after == "[ ]" {
                    marker = .task(checked: false)
                    scanner.consumeCharacters(after == "[ ]" ? 3 : 4)
                } else if after.hasPrefix("[x] ") || after.hasPrefix("[X] ") || after == "[x]" || after == "[X]" {
                    marker = .task(checked: true)
                    scanner.consumeCharacters(after.count == 3 ? 3 : 4)
                }
                containers.append(OpenContainer(kind: .listItem, contentIndent: indent + item.markerLength + spaces, pendingMarker: marker))
                openedContainers = true
                endLastBlock()
            }

            let leafIndent = scanner.indentWidth
            let leaf = BlockParser.trimmingSpaceAndTab(scanner.rest)
            let leafIsSlice = scanner.restIsSliceOfLine
            // An item whose first line is only its marker: its block comes later.
            if leaf.isEmpty { return }

            // 7. The leaf block.
            let sameContext = !openedContainers && allMatched
            if leafIndent >= 4 {
                if canContinue, sameContext {
                    // Indentation does not make code inside a paragraph.
                    blocks[blocks.count - 1].addLine(String(leaf))
                } else {
                    scanner.consumeColumns(4)
                    start(.code(language: nil, fence: nil, fenceLength: 0, indent: 0, closed: false), line: String(scanner.rest))
                }
                return
            }
            if leaf.hasPrefix("<!--") {
                if !BlockParser.containsASCII(leaf, "-->") { inComment = true }
                endLastBlock()
                endLists(from: containers.count)
                return
            }
            // "[label]: url": a definition, not shown. It cannot interrupt a paragraph.
            if !(canContinue && sameContext), !(tableOpen && sameContext), leaf.hasPrefix("["), let definition = BlockParser.linkDefinition(leaf) {
                if definitions[definition.label] == nil { definitions[definition.label] = definition.destination }
                endLastBlock()
                endLists(from: containers.count)
                return
            }
            if let fence = BlockParser.fenceOpener(leaf) {
                start(.code(language: fence.language, fence: fence.character, fenceLength: fence.length, indent: leafIndent, closed: false))
                return
            }
            if let heading = BlockParser.heading(leaf) {
                start(.heading(level: heading.level), line: heading.text)
                return
            }
            if canContinue, sameContext, let level = BlockParser.setextLevel(leaf) {
                blocks[blocks.count - 1].kind = .heading(level: level)
                canContinue = false
                return
            }
            if canContinue, sameContext, let last = blocks.last, last.couldBecomeTable,
               let alignments = BlockParser.delimiterRow(leaf),
               alignments.count == BlockParser.tableCells(last.lastLine ?? "").count {
                blocks[blocks.count - 1].becomeTable(alignments: alignments)
                canContinue = false
                tableOpen = true
                return
            }
            if BlockParser.isRule(leaf) {
                start(.rule)
                return
            }
            if tableOpen, sameContext {
                blocks[blocks.count - 1].addLine(String(leaf))
                return
            }
            if canContinue, sameContext {
                blocks[blocks.count - 1].addLine(String(leaf), units: units(of: leaf, sliceOfLine: leafIsSlice))
            } else {
                start(.paragraph, line: String(leaf), units: units(of: leaf, sliceOfLine: leafIsSlice))
                canContinue = true
            }
        }

        /// Whether an unterminated line should stay hidden for now because the
        /// characters seen so far could still become block markup.
        ///
        /// Once a line is not held back, adding characters to it never makes
        /// it held back again or changes how `process` will classify it, so
        /// what is shown of a partial line stays valid.
        func shouldHoldBack(_ partial: String) -> Bool {
            if lastBlockIsOpenFence, case .code(_, let fence?, _, _, _) = blocks.last?.kind {
                // A prefix of the closing fence would flash as code and then
                // vanish; so would the indentation before it.
                let core = BlockParser.trimmingSpaceAndTab(BlockParser.strippingContainerMarkers(partial).content)
                return core.allSatisfy { $0 == fence }
            }
            let stripped = BlockParser.strippingContainerMarkers(partial)
            let trimmed = BlockParser.trimmingSpaceAndTab(stripped.content)
            if trimmed.isEmpty { return true }
            // Every rule below needs one of these first; most lines are text
            // and are let through here without looking further. This runs on
            // every update while a line is being written.
            guard let first = trimmed.utf8.first, BlockParser.markupStarts.contains(first) else { return false }
            // A task box still being typed.
            if stripped.afterListMarker, "[ ] ".hasPrefix(trimmed) || "[x] ".hasPrefix(trimmed) || "[X] ".hasPrefix(trimmed) {
                return true
            }
            // A fence opener is held until its info string is complete.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { return true }
            if trimmed.allSatisfy({ $0 == "`" }) || trimmed.allSatisfy({ $0 == "~" }) { return true }
            if trimmed.utf8.count <= 6, trimmed.allSatisfy({ $0 == "#" }) { return true }
            if trimmed == ">" || trimmed == "-" || trimmed == "+" || trimmed == "*" { return true }
            // An HTML comment opener.
            if "<!--".hasPrefix(trimmed) { return true }
            // A link reference definition: until the character after the
            // label's "]" shows it is not one, and then until the line is complete.
            if trimmed.hasPrefix("["), BlockParser.couldBeLinkDefinition(trimmed) { return true }
            // "12" or "12." may become an ordered list marker.
            var digits = trimmed
            if let last = digits.last, last == "." || last == ")" { digits = digits.dropLast() }
            if !digits.isEmpty, digits.utf8.count <= 9, digits.allSatisfy({ $0.isASCII && $0.isNumber }) { return true }
            // "--", "* *", "__" may become a rule (or open emphasis, or a setext underline).
            if BlockParser.isRepeatedMark(trimmed, minimumCount: 1) { return true }
            // "===" may underline the paragraph above as a heading.
            if canContinue, trimmed.allSatisfy({ $0 == "=" }) { return true }
            // A table's delimiter row, under a possible header.
            if let last = blocks.last, canContinue, last.couldBecomeTable, trimmed.allSatisfy({ "|:- \t".contains($0) }) {
                return true
            }
            return false
        }

        /// The last block is a possible table header that should not be
        /// shown yet (see `RawBlock.isHiddenWhileOpen`).
        var hidesLastBlock: Bool {
            canContinue && blocks.last?.isHiddenWhileOpen == true
        }
    }

    // MARK: Lines

    /// Reads a line from the left, counting columns (a tab advances to the
    /// next multiple of 4) so that container indentation works with tabs.
    ///
    /// Works on the line's UTF-8 bytes, since everything it looks for is
    /// ASCII, and hands out the rest of the line as a substring: the line is
    /// scanned for every update while it is being written, so it must not
    /// copy it.
    struct LineScanner {
        private let line: Substring
        private var index: String.Index
        private var column = 0
        /// Columns left over from a tab that was only partly consumed.
        private var spareSpaces = 0

        private static let space = UInt8(ascii: " ")
        private static let tab = UInt8(ascii: "\t")
        private static let greaterThan = UInt8(ascii: ">")

        init(_ line: String) {
            self.line = Substring(line)
            index = self.line.startIndex
        }

        /// Columns of whitespace from here, not consumed.
        var indentWidth: Int {
            var width = spareSpaces
            var column = self.column + spareSpaces
            let utf8 = line.utf8
            var index = self.index
            while index < utf8.endIndex {
                let byte = utf8[index]
                if byte == Self.space {
                    width += 1
                    column += 1
                } else if byte == Self.tab {
                    let step = 4 - column % 4
                    width += step
                    column += step
                } else {
                    break
                }
                index = utf8.index(after: index)
            }
            return width
        }

        var restIsBlank: Bool {
            line.utf8[index...].allSatisfy { $0 == Self.space || $0 == Self.tab }
        }

        /// Whether `rest` is a piece of the line itself, not a copy.
        var restIsSliceOfLine: Bool { spareSpaces == 0 }

        /// The line from here on. Only a tab split by the indentation costs a copy.
        var rest: Substring {
            spareSpaces == 0 ? line[index...] : Substring(String(repeating: " ", count: spareSpaces) + line[index...])
        }

        /// Consumes up to `count` columns of whitespace.
        mutating func consumeColumns(_ count: Int) {
            let utf8 = line.utf8
            var remaining = count
            while remaining > 0 {
                if spareSpaces > 0 {
                    let used = min(spareSpaces, remaining)
                    spareSpaces -= used
                    column += used
                    remaining -= used
                    continue
                }
                guard index < utf8.endIndex else { return }
                let byte = utf8[index]
                if byte == Self.space {
                    index = utf8.index(after: index)
                    column += 1
                    remaining -= 1
                } else if byte == Self.tab {
                    let step = 4 - column % 4
                    index = utf8.index(after: index)
                    if step <= remaining {
                        column += step
                        remaining -= step
                    } else {
                        column += remaining
                        spareSpaces = step - remaining
                        remaining = 0
                    }
                } else {
                    return
                }
            }
        }

        mutating func consumeIndent() {
            consumeColumns(indentWidth)
        }

        /// Consumes `count` characters, which are ASCII: a list marker or a task box.
        mutating func consumeCharacters(_ count: Int) {
            spareSpaces = 0
            let utf8 = line.utf8
            for _ in 0..<count where index < utf8.endIndex {
                index = utf8.index(after: index)
                column += 1
            }
        }

        /// Consumes up to three spaces, ">" and one following space, if the
        /// line continues a block quote here.
        @discardableResult
        mutating func consumeQuoteMarker() -> Bool {
            guard indentWidth < 4 else { return false }
            var probe = self
            probe.consumeIndent()
            let utf8 = line.utf8
            guard probe.index < utf8.endIndex, utf8[probe.index] == Self.greaterThan, probe.spareSpaces == 0 else { return false }
            probe.index = utf8.index(after: probe.index)
            probe.column += 1
            if probe.indentWidth > 0 { probe.consumeColumns(1) }
            self = probe
            return true
        }
    }

    /// The first characters of every partial line `shouldHoldBack` may hold.
    static let markupStarts = Set("[`~#>-+*<_=|:0123456789".utf8)

    /// Whether `text` holds the ASCII string `needle`, by bytes. Foundation's
    /// `contains` on strings is far slower, and this runs for every update.
    static func containsASCII<S: StringProtocol>(_ text: S, _ needle: StaticString) -> Bool {
        let pattern = UnsafeBufferPointer(start: needle.utf8Start, count: needle.utf8CodeUnitCount)
        guard let first = pattern.first else { return true }
        let bytes = text.utf8
        var start = bytes.startIndex
        while let found = bytes[start...].firstIndex(of: first) {
            if bytes[found...].starts(with: pattern) { return true }
            start = bytes.index(after: found)
        }
        return false
    }

    /// A partial line with its quote markers and list markers removed, for
    /// the hold-back rules, which look at what is left.
    static func strippingContainerMarkers(_ line: String) -> (content: Substring, afterListMarker: Bool) {
        var rest = Substring(line)
        var afterListMarker = false
        while true {
            let trimmed = rest.drop { $0 == " " || $0 == "\t" }
            if trimmed.hasPrefix(">") {
                rest = trimmed.dropFirst()
                afterListMarker = false
                continue
            }
            // The marker is ASCII, so more bytes than it has means more characters.
            if !isRule(trimmingSpaceAndTab(trimmed)), let item = listMarker(trimmed), trimmed.utf8.count > item.markerLength {
                rest = trimmed.dropFirst(item.markerLength + 1)
                afterListMarker = true
                continue
            }
            return (rest, afterListMarker)
        }
    }

    /// Whether `content` would start a block of its own rather than continue
    /// a paragraph lazily.
    static func startsBlock(_ content: Substring, indent: Int) -> Bool {
        if indent >= 4 { return false }
        if content.hasPrefix(">") || fenceOpener(content) != nil || heading(content) != nil || isRule(content) { return true }
        // Any list item: outside the paragraph's containers it does not
        // interrupt the paragraph, so the rule for that does not apply.
        if listMarker(content) != nil { return true }
        if content.hasPrefix("<!--") { return true }
        return false
    }

    /// Whether a list item can start in the middle of a paragraph: only one
    /// with content, and if numbered, numbered 1.
    static func canInterruptParagraph(_ item: ListItemStart, rest: Substring) -> Bool {
        guard !trimmingSpaceAndTab(rest.dropFirst(item.markerLength)).isEmpty else { return false }
        // The number as written, not as the list would number the item.
        if let number = item.number { return number == 1 }
        return true
    }

    // MARK: Inline source

    private static let space = UInt16(UInt8(ascii: " "))
    private static let tab = UInt16(UInt8(ascii: "\t"))
    private static let backslash = UInt16(UInt8(ascii: "\\"))
    private static let newline = UInt16(UInt8(ascii: "\n"))

    fileprivate static func isBreakSensitive(_ unit: UInt16) -> Bool {
        unit == space || unit == tab || unit == backslash
    }

    /// What a line adds to a block's inline source when another line
    /// follows it: its trimmed text and a space, or a line break if it ends
    /// in two spaces or a backslash (which is dropped, with the spaces
    /// before it). `trimmed` is the line trimmed, as UTF-16; a line on its
    /// own, with nothing after it, contributes just that.
    fileprivate static func contributionWhenFollowed(_ trimmed: [UInt16], of line: String) -> [UInt16] {
        let bytes = line.utf8
        var units = trimmed
        var hardBreak = bytes.count >= 2 && bytes.suffix(2).elementsEqual([0x20, 0x20])
        if bytes.last == 0x5C, !units.isEmpty {
            hardBreak = true
            units.removeLast()
            while let last = units.last, last == space || last == tab { units.removeLast() }
        }
        units.append(hardBreak ? newline : space)
        return units
    }

    /// UTF-16 code units, decoded straight from the UTF-8 storage. Going
    /// through a substring's `utf16` view costs far more, and the line being
    /// written is converted on every update.
    static func utf16<S: StringProtocol>(_ text: S) -> [UInt16] {
        var units: [UInt16] = []
        units.reserveCapacity(text.utf8.count)
        let decoded: Void? = text.utf8.withContiguousStorageIfAvailable { bytes in
            var i = 0
            let count = bytes.count
            while i < count {
                let first = UInt32(bytes[i])
                if first < 0x80 {
                    units.append(UInt16(first))
                    i += 1
                    continue
                }
                let scalar: UInt32
                if first < 0xE0 {
                    scalar = (first & 0x1F) << 6 | UInt32(bytes[i + 1] & 0x3F)
                    i += 2
                } else if first < 0xF0 {
                    scalar = (first & 0x0F) << 12 | UInt32(bytes[i + 1] & 0x3F) << 6 | UInt32(bytes[i + 2] & 0x3F)
                    i += 3
                } else {
                    scalar = (first & 0x07) << 18 | UInt32(bytes[i + 1] & 0x3F) << 12
                        | UInt32(bytes[i + 2] & 0x3F) << 6 | UInt32(bytes[i + 3] & 0x3F)
                    i += 4
                }
                if scalar < 0x10000 {
                    units.append(UInt16(scalar))
                } else {
                    let value = scalar - 0x10000
                    units.append(UInt16(0xD800 + (value >> 10)))
                    units.append(UInt16(0xDC00 + (value & 0x3FF)))
                }
            }
        }
        // Not stored as UTF-8 (a bridged string): the slow way.
        return decoded == nil ? Array(text.utf16) : units
    }

    /// Leading and trailing spaces and tabs removed. The block and inline
    /// parsers trim the same set, so text never reappears after being trimmed.
    ///
    /// By bytes: stepping a substring back by one character can cost as
    /// much as walking all of it, and lines are trimmed on every update.
    static func trimmingSpaceAndTab(_ text: Substring) -> Substring {
        let bytes = text.utf8
        var start = bytes.startIndex
        var end = bytes.endIndex
        while start < end, bytes[start] == 0x20 || bytes[start] == 0x09 { start = bytes.index(after: start) }
        while end > start {
            let before = bytes.index(before: end)
            guard bytes[before] == 0x20 || bytes[before] == 0x09 else { break }
            end = before
        }
        // A space that a combining mark follows belongs to that character,
        // which is not whitespace: keep it, as trimming by characters would.
        if start > bytes.startIndex, start < end {
            let previous = bytes.index(before: start)
            if let character = text[previous...].first, character != " ", character != "\t" { start = previous }
        }
        return text[start..<end]
    }

    // MARK: Line classification

    static func dropIndent(_ line: Substring, upTo indent: Int) -> String {
        var remaining = indent
        var index = line.startIndex
        while remaining > 0, index < line.endIndex, line[index] == " " {
            index = line.index(after: index)
            remaining -= 1
        }
        return String(line[index...])
    }

    static func fenceOpener(_ content: Substring) -> (character: Character, length: Int, language: String?)? {
        guard let first = content.first, first == "`" || first == "~" else { return nil }
        let length = content.prefix { $0 == first }.count
        guard length >= 3 else { return nil }
        let info = trimmingSpaceAndTab(content.dropFirst(length))
        if first == "`", info.utf8.contains(UInt8(ascii: "`")) { return nil }
        let language = info.split(separator: " ").first.map(String.init)
        return (first, length, language)
    }

    static func isClosingFence(_ line: Substring, character: Character, length: Int) -> Bool {
        let trimmed = trimmingSpaceAndTab(line)
        return trimmed.count >= length && trimmed.allSatisfy { $0 == character }
    }

    static func heading(_ content: Substring) -> (level: Int, text: String)? {
        let level = content.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let rest = content.dropFirst(level)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        // An optional closing sequence of "#"s goes too: "## Title ##".
        var text = trimmingSpaceAndTab(rest)
        if let lastNonHash = text.lastIndex(where: { $0 != "#" }) {
            let closing = text[text.index(after: lastNonHash)...]
            if !closing.isEmpty, text[lastNonHash] == " " || text[lastNonHash] == "\t" {
                text = trimmingSpaceAndTab(text[...lastNonHash])
            }
        } else {
            text = ""
        }
        return (level, String(text))
    }

    /// "===" makes the paragraph above a level 1 heading, "---" level 2.
    static func setextLevel(_ content: Substring) -> Int? {
        let core = trimmingSpaceAndTab(content)
        guard let first = core.first, first == "=" || first == "-", core.allSatisfy({ $0 == first }) else { return nil }
        return first == "=" ? 1 : 2
    }

    static func isRule(_ content: Substring) -> Bool {
        isRepeatedMark(content, minimumCount: 3)
    }

    /// At least `minimumCount` of one of `-`, `*`, `_`, and nothing else but
    /// spaces and tabs. Stops at the first other character.
    fileprivate static func isRepeatedMark(_ content: Substring, minimumCount: Int) -> Bool {
        var mark: Character?
        var count = 0
        for character in content {
            if character == " " || character == "\t" { continue }
            if let mark {
                guard character == mark else { return false }
            } else {
                guard character == "-" || character == "*" || character == "_" else { return false }
                mark = character
            }
            count += 1
        }
        return count >= minimumCount
    }

    /// A list item's marker as written.
    struct ListItemStart {
        let marker: TranscriptBlock.ListMarker
        let markerLength: Int
        /// The bullet, or the delimiter after the number.
        let character: Character
        /// For an ordered item, its number as written.
        let number: Int?
    }

    /// A list marker at the start of `content`, followed by a space, a tab or
    /// the end of the line.
    static func listMarker(_ content: Substring) -> ListItemStart? {
        guard let first = content.first else { return nil }
        let start: ListItemStart
        if "-+*".contains(first) {
            start = ListItemStart(marker: .bullet, markerLength: 1, character: first, number: nil)
        } else {
            let digits = content.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, digits.count <= 9 else { return nil }
            let rest = content.dropFirst(digits.count)
            guard let delimiter = rest.first, delimiter == "." || delimiter == ")" else { return nil }
            start = ListItemStart(marker: .number("\(digits)\(delimiter)"), markerLength: digits.count + 1,
                                  character: delimiter, number: Int(digits))
        }
        let after = content.dropFirst(start.markerLength)
        guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
        return start
    }

    // MARK: Link reference definitions

    /// A label as definitions and references are matched: lowercased, with
    /// runs of whitespace as one space and none at the ends.
    static func normalizedLabel<S: StringProtocol>(_ label: S) -> String {
        label.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).joined(separator: " ")
    }

    /// The end of a label that starts at `content`'s "[": the index of its
    /// "]", or nil if there is none on the line. Labels hold no unescaped
    /// brackets and at most 999 characters.
    private static func labelEnd(in content: Substring) -> String.Index? {
        var index = content.index(after: content.startIndex)
        var length = 0
        while index < content.endIndex, length <= 999 {
            let character = content[index]
            if character == "\\" {
                index = content.index(after: index)
                if index < content.endIndex { index = content.index(after: index) }
                length += 2
                continue
            }
            if character == "[" { return nil }
            if character == "]" { return index }
            index = content.index(after: index)
            length += 1
        }
        return nil
    }

    /// Whether a partial line starting with "[" may still be a definition.
    static func couldBeLinkDefinition(_ content: Substring) -> Bool {
        guard let end = labelEnd(in: content) else {
            // Still inside the label, unless it is already too long to be one.
            return content.utf8.count <= 4004 && !content.utf8.dropFirst().contains(UInt8(ascii: "["))
        }
        let after = content.index(after: end)
        return after == content.endIndex || content[after] == ":"
    }

    /// `[label]: destination "optional title"` on one line.
    static func linkDefinition(_ content: Substring) -> (label: String, destination: String)? {
        guard let end = labelEnd(in: content) else { return nil }
        let rawLabel = content[content.index(after: content.startIndex)..<end]
        let label = normalizedLabel(rawLabel)
        guard !label.isEmpty else { return nil }
        var rest = content[content.index(after: end)...]
        guard rest.first == ":" else { return nil }
        rest = trimmingSpaceAndTab(rest.dropFirst())
        let destination: Substring
        if rest.first == "<" {
            guard let close = rest.firstIndex(of: ">") else { return nil }
            destination = rest[rest.index(after: rest.startIndex)..<close]
            rest = rest[rest.index(after: close)...]
        } else {
            destination = rest.prefix { $0 != " " && $0 != "\t" }
            guard !destination.isEmpty else { return nil }
            rest = rest.dropFirst(destination.count)
        }
        // Then nothing, or a title in quotes or parentheses.
        let title = trimmingSpaceAndTab(rest)
        if !title.isEmpty {
            guard rest.first == " " || rest.first == "\t", let open = title.first, let close = title.last, title.count >= 2 else { return nil }
            let pairs: [Character: Character] = ["\"": "\"", "'": "'", "(": ")"]
            guard pairs[open] == close else { return nil }
        }
        return (label, String(destination))
    }

    // MARK: Tables

    /// A row's cells: split on "|" (not "\|"), without the outer pipes.
    static func tableCells(_ line: String) -> [String] {
        var row = trimmingSpaceAndTab(Substring(line))
        if row.hasPrefix("|") { row = row.dropFirst() }
        if row.hasSuffix("|"), !row.hasSuffix("\\|") { row = row.dropLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in row {
            if escaped {
                // "\|" is a literal pipe; other escapes are left for the inline parser.
                current += character == "|" ? "|" : "\\" + String(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(String(trimmingSpaceAndTab(Substring(current))))
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current += "\\" }
        cells.append(String(trimmingSpaceAndTab(Substring(current))))
        return cells
    }

    /// The column alignments if `content` is a delimiter row such as
    /// "| --- | :---: | ---: |".
    static func delimiterRow(_ content: Substring) -> [TranscriptTable.Alignment]? {
        guard content.utf8.contains(UInt8(ascii: "-")), content.allSatisfy({ "|:- \t".contains($0) }) else { return nil }
        let cells = tableCells(String(content))
        var alignments: [TranscriptTable.Alignment] = []
        for cell in cells {
            let core = trimmingSpaceAndTab(Substring(cell))
            guard core.utf8.contains(UInt8(ascii: "-")), core.dropFirst().dropLast().allSatisfy({ $0 == "-" }) || core.count <= 2 else { return nil }
            let left = core.hasPrefix(":")
            let right = core.hasSuffix(":")
            alignments.append(left && right ? .center : (right ? .trailing : .leading))
        }
        return alignments.isEmpty ? nil : alignments
    }
}
