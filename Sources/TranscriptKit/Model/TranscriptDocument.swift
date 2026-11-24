import Foundation

/// Styling for a range of a block's text.
public struct InlineSpan: Equatable, Sendable {
    public struct Traits: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let bold = Traits(rawValue: 1 << 0)
        public static let italic = Traits(rawValue: 1 << 1)
        public static let code = Traits(rawValue: 1 << 2)
        public static let strikethrough = Traits(rawValue: 1 << 3)
        public static let underline = Traits(rawValue: 1 << 4)
    }

    /// UTF-16 offsets into the block's text.
    public var range: Range<Int>
    public var traits: Traits
    /// Link destination, if this range is a link.
    public var link: String?
    /// The fields few spans have, kept out of line: parsing and layout copy
    /// spans a lot, and the size of a span is much of what that costs.
    private(set) var extras: Extras?

    /// An image, shown in place of the range's single U+FFFC character.
    public var image: TranscriptImage? {
        get { extras?.image }
        set { extras = Extras.make(image: newValue, reference: reference, customTag: customTag, math: math) }
    }

    /// A formula, shown in place of the range's single U+FFFC character.
    public var math: TranscriptMath? {
        get { extras?.math }
        set { extras = Extras.make(image: image, reference: reference, customTag: customTag, math: newValue) }
    }

    /// For a reference link (`[text][label]`, `[label][]` or `[label]`): its
    /// label, normalised. It is a link once the document defines the label
    /// (`[label]: url`), which may happen further down; see
    /// `TranscriptDocument.destination(of:)`.
    public var reference: String? {
        get { extras?.reference }
        set { extras = Extras.make(image: image, reference: newValue, customTag: customTag, math: math) }
    }

    /// For text inside a custom tag (see `TranscriptTag`): the tag and its
    /// decoration. In a parsed span, and in one made with
    /// `InlineSpan(range:tagged:)`, its traits and link are also in `traits`
    /// and `link`. Setting it does not change them.
    public var customTag: CustomTag? {
        get { extras?.customTag }
        set { extras = Extras.make(image: image, reference: reference, customTag: newValue, math: math) }
    }

    public init(range: Range<Int>, traits: Traits = [], link: String? = nil, image: TranscriptImage? = nil,
                reference: String? = nil, customTag: CustomTag? = nil, math: TranscriptMath? = nil) {
        self.range = range
        self.traits = traits
        self.link = link
        self.extras = Extras.make(image: image, reference: reference, customTag: customTag, math: math)
    }

    /// A span for text inside a custom tag, as the parser makes it: with
    /// the tag's decoration, its traits, and its link. For a document that
    /// the app builds without the parser.
    public init(range: Range<Int>, tagged tag: CustomTag) {
        self.init(range: range, traits: tag.decoration.traits, link: tag.decoration.link, customTag: tag)
    }

    init(range: Range<Int>, traits: Traits, link: String?, extras: Extras?) {
        self.range = range
        self.traits = traits
        self.link = link
        self.extras = extras
    }

    /// Immutable, so spans can share one.
    final class Extras: Equatable, Sendable {
        let image: TranscriptImage?
        let reference: String?
        let customTag: CustomTag?
        let math: TranscriptMath?

        private init(image: TranscriptImage?, reference: String?, customTag: CustomTag?, math: TranscriptMath?) {
            self.image = image
            self.reference = reference
            self.customTag = customTag
            self.math = math
        }

        /// Nil when there is nothing to keep.
        static func make(image: TranscriptImage?, reference: String?, customTag: CustomTag?, math: TranscriptMath? = nil) -> Extras? {
            image == nil && reference == nil && customTag == nil && math == nil
                ? nil : Extras(image: image, reference: reference, customTag: customTag, math: math)
        }

        static func == (a: Extras, b: Extras) -> Bool {
            a === b || (a.image == b.image && a.reference == b.reference && a.customTag == b.customTag && a.math == b.math)
        }
    }
}

/// A LaTeX formula in the text: `\( … \)` inline, or display math, which is
/// `$$ … $$` or a block that starts with `\[` or `$$` at the start of a line.
/// It is drawn by the app's renderer; see `TranscriptTextView.mathRenderer`.
public struct TranscriptMath: Equatable, Hashable, Sendable {
    /// The formula's LaTeX, without its delimiters.
    public var tex: String
    /// Display math, set on its own, rather than math in a line of text.
    public var isDisplay: Bool

    public init(tex: String, isDisplay: Bool) {
        self.tex = tex
        self.isDisplay = isDisplay
    }

    /// The formula as written, with delimiters: what copying gives.
    public var source: String { isDisplay ? "\\[" + tex + "\\]" : "\\(" + tex + "\\)" }
}

/// An image in the text, `![alt](source)` in Markdown.
public struct TranscriptImage: Equatable, Hashable, Sendable {
    public var source: String
    public var alt: String

    public init(source: String, alt: String) {
        self.source = source
        self.alt = alt
    }
}

/// A table's structure. Its cells are ranges of the block's text, in which
/// cells are separated by a tab and rows by a newline, header row first.
public struct TranscriptTable: Equatable, Sendable {
    public enum Alignment: Equatable, Sendable {
        case leading
        case center
        case trailing
    }

    public var alignments: [Alignment]
    /// Cell ranges, row by row; the first row is the header.
    public var rows: [[Range<Int>]]

    public init(alignments: [Alignment], rows: [[Range<Int>]]) {
        self.alignments = alignments
        self.rows = rows
    }

    public var columnCount: Int { alignments.count }

    /// Whether `newer` is this table with cells or rows only added at the
    /// end, and the last cell perhaps longer: the structure of a table whose
    /// text grew at its end.
    func isExtended(by newer: TranscriptTable) -> Bool {
        guard alignments == newer.alignments, newer.rows.count >= rows.count else { return false }
        guard let lastRow = rows.indices.last else { return true }
        for index in 0..<lastRow where rows[index] != newer.rows[index] { return false }
        let old = rows[lastRow]
        let new = newer.rows[lastRow]
        guard new.count >= old.count else { return false }
        guard let lastCell = old.indices.last else { return true }
        return old[..<lastCell] == new[..<lastCell] && old[lastCell].lowerBound == new[lastCell].lowerBound
    }
}

/// One block of a transcript.
public struct TranscriptBlock: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case paragraph
        case heading(level: Int)
        case code(language: String? = nil)
        /// A horizontal rule. Its text is empty.
        case rule
        case table(TranscriptTable)

        var isCode: Bool {
            if case .code = self { return true }
            return false
        }

        var table: TranscriptTable? {
            if case .table(let table) = self { return table }
            return nil
        }

        /// Whether a block of kind `newer` can be this block with text added
        /// at the end. The same kind, except that a table grows.
        func isExtended(by newer: Kind) -> Bool {
            if case .table(let old) = self, case .table(let new) = newer { return old.isExtended(by: new) }
            return self == newer
        }
    }

    /// Something a block sits inside: a block quote or a list item.
    public enum Container: Equatable, Sendable {
        case quote
        case listItem
    }

    /// What is drawn in the gutter of a list item's first block.
    public enum ListMarker: Equatable, Sendable {
        case bullet
        /// The item's number and the delimiter after it, such as "3." or
        /// "3)". Items are numbered as CommonMark numbers them: the first
        /// item's number as written, then one more for each item.
        case number(String)
        case task(checked: Bool)
    }

    public var id: String
    public var kind: Kind
    /// The text as displayed, with any markup already removed.
    public var text: String
    public var spans: [InlineSpan]
    /// The block quotes and list items this block is inside, outermost first.
    public var containers: [Container]
    /// Set on the first block of a list item.
    public var marker: ListMarker?

    public init(id: String = UUID().uuidString, kind: Kind = .paragraph, text: String, spans: [InlineSpan] = [],
                containers: [Container] = [], marker: ListMarker? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.spans = spans
        self.containers = containers
        self.marker = marker
    }

    /// How many block quotes the block is in.
    public var quoteLevel: Int { containers.reduce(0) { $0 + ($1 == .quote ? 1 : 0) } }
    /// How many list items the block is in.
    public var listLevel: Int { containers.reduce(0) { $0 + ($1 == .listItem ? 1 : 0) } }

    var utf16Count: Int { text.utf16.count }

    /// Whether `newer` is this block with text only added at the end and the
    /// existing text styled as before. A span that ran to the end of the old
    /// text may have grown (unclosed markup keeps extending while streaming).
    func isStyledPrefix(of newer: TranscriptBlock) -> Bool {
        guard id == newer.id, kind.isExtended(by: newer.kind), containers == newer.containers, marker == newer.marker,
              newer.text.utf8HasPrefix(text), newer.spans.count >= spans.count else { return false }
        let oldLength = utf16Count
        for (old, new) in zip(spans, newer.spans) {
            // Spans made by the same parse share their rarely set fields, so
            // most compare by identity.
            guard old.range.lowerBound == new.range.lowerBound, old.traits == new.traits,
                  (old.link == nil) == (new.link == nil),
                  old.extras === new.extras || (old.image == new.image && old.reference == new.reference
                                                && old.customTag?.decoration == new.customTag?.decoration
                                                // An animated tag that closed now draws its shapes.
                                                && old.customTag?.isOpen == new.customTag?.isOpen) else { return false }
            if old.range.upperBound != new.range.upperBound, old.range.upperBound != oldLength { return false }
        }
        // Any further spans must start in the new text.
        return newer.spans.dropFirst(spans.count).allSatisfy { $0.range.lowerBound >= oldLength }
    }
}

extension String {
    /// `hasPrefix` by bytes. `hasPrefix` compares by canonical equivalence,
    /// which is slower and not what layout reuse needs.
    func utf8HasPrefix(_ prefix: String) -> Bool {
        var whole = self
        var start = prefix
        return whole.withUTF8 { wholeBytes in
            start.withUTF8 { prefixBytes in
                prefixBytes.count <= wholeBytes.count
                    && (prefixBytes.isEmpty || memcmp(wholeBytes.baseAddress!, prefixBytes.baseAddress!, prefixBytes.count) == 0)
            }
        }
    }
}

/// An append-oriented list of blocks.
///
/// The document exposes one flat UTF-16 offset space: the blocks' texts joined
/// by a single "\n". Selection and hit testing work in that space, which is
/// what lets one selection run across every block.
///
/// Storage is split in two so that a streaming update costs the same however
/// long the document is: `settled` blocks no longer change and their storage
/// is shared between successive versions of the document (appending to it
/// copies nothing), while `open` holds the block or two still being written.
public struct TranscriptDocument: Equatable, Sendable {
    private(set) var settled: SharedList<TranscriptBlock>
    private(set) var open: [TranscriptBlock]
    /// Sum of the settled blocks' UTF-16 lengths.
    private var settledLength: Int
    /// Link reference definitions (`[label]: url`), by label: lowercased,
    /// with runs of whitespace as one space and none at the ends. The
    /// parser keeps the first definition of each label.
    public var linkDefinitions: [String: String]

    /// All blocks in order. This builds a new array; prefer `count` and
    /// `block(at:)` in code that runs on every update.
    public var blocks: [TranscriptBlock] { Array(settled) + open }

    public var count: Int { settled.count + open.count }

    public func block(at index: Int) -> TranscriptBlock {
        index < settled.count ? settled[index] : open[index - settled.count]
    }

    public init(blocks: [TranscriptBlock] = []) {
        self.init(settled: SharedList(blocks), open: [], settledLength: blocks.reduce(0) { $0 + $1.utf16Count })
    }

    /// For the parser: successive versions should append to the same
    /// `settled` list, so that they can be compared without looking at it.
    init(settled: SharedList<TranscriptBlock>, open: [TranscriptBlock], settledLength: Int, linkDefinitions: [String: String] = [:]) {
        self.linkDefinitions = linkDefinitions
        self.settled = settled
        self.open = open
        self.settledLength = settledLength
    }

    public mutating func append(_ block: TranscriptBlock) {
        open.append(block)
    }

    /// Appends streamed text to the last block, creating a paragraph if empty.
    public mutating func appendToLastBlock(_ text: String) {
        if open.isEmpty {
            if !settled.isEmpty {
                let last = settled.removeLast()
                settledLength -= last.utf16Count
                open.append(last)
            } else {
                open.append(TranscriptBlock(text: ""))
            }
        }
        open[open.count - 1].text += text
    }

    // MARK: Comparing versions

    /// How many leading blocks are known to be the same in both documents
    /// without comparing them, because their settled blocks share storage.
    func knownSharedPrefix(with other: TranscriptDocument) -> Int {
        if settled.count <= other.settled.count {
            return other.settled.extendsStorage(of: settled) ? settled.count : 0
        }
        return settled.extendsStorage(of: other.settled) ? other.settled.count : 0
    }

    /// Documents are compared on every update. While streaming, successive
    /// versions share their settled storage and differ in the open part, so
    /// only a block or two is ever compared.
    public static func == (lhs: TranscriptDocument, rhs: TranscriptDocument) -> Bool {
        // Definitions count: a new one changes where links go, not the text.
        guard lhs.count == rhs.count, lhs.linkDefinitions == rhs.linkDefinitions else { return false }
        let known = lhs.knownSharedPrefix(with: rhs)
        // From the end: the last block is the one most likely to differ.
        var index = lhs.count - 1
        while index >= known {
            if lhs.block(at: index) != rhs.block(at: index) { return false }
            index -= 1
        }
        return true
    }

    /// Whether this document is `earlier` with content only added at the end:
    /// new blocks, or more text in the last block. Every offset that was valid
    /// in `earlier` then still points at the same character.
    public func extends(_ earlier: TranscriptDocument) -> Bool {
        let oldCount = earlier.count
        guard oldCount > 0 else { return true }
        guard count >= oldCount else { return false }
        let last = oldCount - 1
        let known = min(knownSharedPrefix(with: earlier), last)
        for index in known..<last where block(at: index) != earlier.block(at: index) { return false }
        let tail = block(at: last)
        let oldTail = earlier.block(at: last)
        return tail.id == oldTail.id && oldTail.kind.isExtended(by: tail.kind) && tail.containers == oldTail.containers
            && tail.marker == oldTail.marker && tail.text.utf8HasPrefix(oldTail.text)
    }

    /// Where a span links to: its own destination, or for a reference link,
    /// the definition of its label, if the document has one.
    public func destination(of span: InlineSpan) -> String? {
        span.link ?? span.reference.flatMap { linkDefinitions[$0] }
    }

    /// Length of the flat offset space.
    public var utf16Count: Int {
        settledLength + open.reduce(0) { $0 + $1.utf16Count } + max(count - 1, 0)
    }

    /// The flat text in `range`, with "\n" between blocks.
    public func text(in range: Range<Int>) -> String {
        var result = ""
        var start = 0
        for (index, block) in blocks.enumerated() {
            let length = block.utf16Count
            let lower = max(range.lowerBound, start)
            let upper = min(range.upperBound, start + length)
            if lower < upper {
                let local = NSRange(location: lower - start, length: upper - lower)
                result += (block.text as NSString).substring(with: local)
            }
            // The separator sits at offset `start + length`.
            if index < blocks.count - 1, range.contains(start + length) {
                result += "\n"
            }
            start += length + 1
            if start >= range.upperBound { break }
        }
        return result
    }

    /// The text in `range` as it should land on the pasteboard: like
    /// `text(in:)`, but readable as Markdown. List markers, task boxes and
    /// quote prefixes are restored, rules are written as "---", tables as
    /// Markdown tables and images as their alt text, with a blank line
    /// between blocks that are not neighbouring list content.
    public func copyText(in range: Range<Int>) -> String {
        var result = ""
        var previousWasInList = false
        var start = 0
        for block in blocks {
            let length = block.utf16Count
            defer { start += length + 1 }
            if start > range.upperBound { break }

            let lower = max(range.lowerBound, start)
            let upper = min(range.upperBound, start + length)
            let includesStart = range.lowerBound <= start && range.upperBound > start
            var piece: String
            switch block.kind {
            case .rule:
                guard includesStart else { continue }
                piece = "---"
            case .table(let table):
                guard lower < upper || includesStart else { continue }
                piece = Self.markdownTable(table, text: block.text, local: (lower - start)..<(upper - start))
            case .paragraph, .heading, .code:
                guard lower < upper else { continue }
                let local = NSRange(location: lower - start, length: upper - lower)
                let text = NSMutableString(string: (block.text as NSString).substring(with: local))
                // Images by their alt text and formulas by their LaTeX, last
                // first so offsets stay valid.
                for span in block.spans.reversed() where local.contains(span.range.lowerBound) {
                    guard let replacement = span.image?.alt ?? span.math?.source else { continue }
                    text.replaceCharacters(in: NSRange(location: span.range.lowerBound - local.location, length: 1), with: replacement)
                }
                piece = text as String
            }

            // Container prefixes: the first line gets the list marker, later
            // lines the item's indentation; every line gets quote markers.
            var firstPrefix = ""
            var restPrefix = ""
            let lastItem = block.containers.lastIndex(of: .listItem)
            for (index, container) in block.containers.enumerated() {
                switch container {
                case .quote:
                    firstPrefix += "> "
                    restPrefix += "> "
                case .listItem:
                    if index == lastItem, let marker = block.marker, includesStart {
                        let text: String
                        switch marker {
                        case .bullet: text = "- "
                        case .number(let number): text = number + " "
                        case .task(let checked): text = checked ? "- [x] " : "- [ ] "
                        }
                        firstPrefix += text
                        restPrefix += String(repeating: " ", count: text.count)
                    } else {
                        firstPrefix += "  "
                        restPrefix += "  "
                    }
                }
            }
            // A selection that starts inside the block starts mid-line.
            if !includesStart { firstPrefix = "" }
            if !firstPrefix.isEmpty || !restPrefix.isEmpty {
                let lines = piece.components(separatedBy: "\n")
                piece = lines.enumerated().map { ($0.offset == 0 ? firstPrefix : restPrefix) + $0.element }.joined(separator: "\n")
            }

            let isInList = block.listLevel > 0
            if !result.isEmpty { result += previousWasInList && isInList ? "\n" : "\n\n" }
            result += piece
            previousWasInList = isInList
        }
        return result
    }

    /// The rows of `table` that `local` touches, as a Markdown table.
    private static func markdownTable(_ table: TranscriptTable, text: String, local: Range<Int>) -> String {
        let string = text as NSString
        var lines: [String] = []
        for (index, row) in table.rows.enumerated() {
            guard let first = row.first, let last = row.last,
                  first.lowerBound < max(local.upperBound, local.lowerBound + 1), last.upperBound >= local.lowerBound else { continue }
            let cells = row.map { string.substring(with: NSRange(location: $0.lowerBound, length: $0.count)) }
            lines.append("| " + cells.joined(separator: " | ") + " |")
            if index == 0 {
                let rule = table.alignments.map { alignment -> String in
                    switch alignment {
                    case .leading: return "---"
                    case .center: return ":---:"
                    case .trailing: return "---:"
                    }
                }
                lines.append("| " + rule.joined(separator: " | ") + " |")
            }
        }
        return lines.joined(separator: "\n")
    }
}
