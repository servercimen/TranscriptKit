import CoreGraphics
import Foundation

/// What assistive technologies get for one block on screen. It is made from
/// a layout without UIKit, so that it can be tested on macOS.
struct AccessibilityItem: Equatable {
    struct Link: Equatable {
        let title: String
        let url: URL
    }

    /// A table's cells, each an element of its own.
    struct Table: Equatable {
        struct Cell: Equatable {
            let row: Int
            let column: Int
            let frame: CGRect
            let label: String
            /// For the first cell of a table that starts a list item: the
            /// item's position, as for a block.
            let value: String?
            let links: [Link]
        }

        let rowCount: Int
        let columnCount: Int
        /// Row by row; the first row is the header.
        let cells: [Cell]
    }

    /// A block's id, and how many blocks before it have the same id.
    struct Key: Hashable {
        let id: String
        let occurrence: Int
    }

    /// Unique in the document: an element keeps it from one layout to the
    /// next, so VoiceOver focus stays on the block while text streams in.
    let key: Key
    let frame: CGRect
    /// What VoiceOver says: the list marker, then the text. Empty for a
    /// table: its first cell has the list marker and the position.
    let label: String
    /// For the first block of a list item: its position in its list and the
    /// number of items in the list, such as "Item 2 of 3".
    let value: String?
    let isHeading: Bool
    /// The links in the text. Each is an action that opens it.
    let links: [Link]
    let table: Table?
}

extension DocumentLayout {
    /// One item for each block on screen that has text, in reading order.
    ///
    /// Under a line limit, the last item holds all of its block's text and
    /// the text of the blocks that the limit leaves out, as a label that is
    /// cut short still reads all of its text. When the last block shown is
    /// a table, the text left out gets an item of its own after it.
    ///
    /// - Parameter math: the words for a formula.
    /// - Parameter words: the words of the items made before with the same
    ///   `math`, which blocks whose layout did not change use again.
    func accessibilityItems(math: (TranscriptMath) -> String = \.tex, words: AccessibilityWords? = nil) -> [AccessibilityItem] {
        var items: [AccessibilityItem] = []
        let definitions = document.linkDefinitions
        words?.begin(definitions: definitions)
        defer { words?.end() }
        let positions = AccessibilityText.listPositions(in: document, upTo: entryCount)
        var uses: [String: Int] = [:]
        func key(for block: TranscriptBlock) -> AccessibilityItem.Key {
            let use = uses[block.id, default: 0]
            uses[block.id] = use + 1
            return AccessibilityItem.Key(id: block.id, occurrence: use)
        }
        for index in 0..<entryCount {
            let entry = entry(at: index)
            let block = entry.layout.block
            let key = key(for: block)
            let made = words?.words(for: key, layout: entry.layout) ?? Self.accessibilityWords(of: entry.layout, math: math,
                                                                                               definitions: definitions)
            words?.keep(made, for: key, layout: entry.layout)
            if let model = block.kind.table, let grid = entry.layout.table {
                let table = Self.accessibilityTable(model, grid: grid, of: block, at: entry.y,
                                                    rightToLeft: entry.layout.isRightToLeft, words: made.cells,
                                                    position: positions[index].map(AccessibilityText.position))
                guard !table.cells.isEmpty else { continue }
                items.append(AccessibilityItem(key: key, frame: entry.frame, label: "", value: nil, isHeading: false,
                                               links: [], table: table))
                continue
            }
            if made.text.isEmpty, block.kind != .rule { continue }
            items.append(AccessibilityItem(key: key, frame: entry.frame, label: AccessibilityText.spoken(made.text, of: block),
                                           value: positions[index].map(AccessibilityText.position),
                                           isHeading: block.kind.isHeading, links: made.links, table: nil))
        }
        guard leavesTextOut, entryCount < document.count else { return items }
        var rest: [String] = []
        var links: [AccessibilityItem.Link] = []
        for index in entryCount..<document.count {
            let block = document.block(at: index)
            let all = 0..<block.utf16Count
            var text = AccessibilityText.readable(block, in: all, math: math)
            if text.isEmpty, block.kind != .rule { continue }
            if block.kind.table != nil { text = text.replacingOccurrences(of: "\t", with: ", ") }
            rest.append(AccessibilityText.spoken(text, of: block))
            links += AccessibilityText.links(of: block, in: all, math: math, definitions: definitions)
        }
        guard !rest.isEmpty else { return items }
        if !items.isEmpty, !hasAccessibilityRemainder {
            let last = items[items.count - 1]
            items[items.count - 1] = AccessibilityItem(key: last.key, frame: last.frame, label: ([last.label] + rest).joined(separator: "\n"),
                                                       value: last.value, isHeading: last.isHeading, links: last.links + links,
                                                       table: nil)
        } else {
            let frame = items.last?.frame ?? CGRect(x: 0, y: 0, width: width, height: height)
            items.append(AccessibilityItem(key: key(for: document.block(at: entryCount)), frame: frame,
                                           label: rest.joined(separator: "\n"), value: nil, isHeading: false, links: links, table: nil))
        }
        return items
    }

    /// The words of a block: its text and links, or for a table the text
    /// and links of each cell that `accessibilityTable` makes, in its order.
    private static func accessibilityWords(of layout: BlockLayout, math: (TranscriptMath) -> String,
                                           definitions: [String: String]) -> AccessibilityWords.Words {
        let block = layout.block
        guard let model = block.kind.table, let grid = layout.table else {
            let all = 0..<block.utf16Count
            return .init(text: AccessibilityText.readable(block, in: all, math: math),
                         links: AccessibilityText.links(of: block, in: all, math: math, definitions: definitions), cells: [])
        }
        let (rowCount, columnCount) = accessibilityGridSize(model, grid: grid)
        let ranges = model.rows.prefix(rowCount).flatMap { $0.prefix(columnCount) }
        let spans = AccessibilityText.spans(of: block, startingIn: ranges)
        let cells = zip(ranges, spans).map { range, spans in
            AccessibilityWords.Words(text: AccessibilityText.readable(block, in: range, spans: spans, math: math),
                                     links: AccessibilityText.links(of: block, in: range, spans: spans, math: math,
                                                                    definitions: definitions),
                                     cells: [])
        }
        return .init(text: "", links: [], cells: cells)
    }

    private static func accessibilityTable(_ model: TranscriptTable, grid: BlockLayout.Table, of block: TranscriptBlock, at y: CGFloat,
                                           rightToLeft: Bool, words: [AccessibilityWords.Words],
                                           position: String?) -> AccessibilityItem.Table {
        var cells: [AccessibilityItem.Table.Cell] = []
        let (rowCount, columnCount) = accessibilityGridSize(model, grid: grid)
        for row in 0..<rowCount {
            for column in 0..<min(model.rows[row].count, columnCount) where cells.count < words.count {
                // The column edges go from left to right, and a right-to-left table starts on the right.
                let edge = rightToLeft ? grid.columnX.count - 2 - column : column
                let frame = CGRect(x: grid.columnX[edge], y: y + grid.rowY[row], width: grid.columnX[edge + 1] - grid.columnX[edge],
                                   height: grid.rowY[row + 1] - grid.rowY[row])
                let cell = words[cells.count]
                let isFirst = cells.isEmpty
                cells.append(.init(row: row, column: column, frame: frame,
                                   label: isFirst ? AccessibilityText.spoken(cell.text, of: block) : cell.text,
                                   value: isFirst ? position : nil, links: cell.links))
            }
        }
        return AccessibilityItem.Table(rowCount: rowCount, columnCount: columnCount, cells: cells)
    }

    /// The rows and columns of a table that have a place in its grid.
    private static func accessibilityGridSize(_ model: TranscriptTable, grid: BlockLayout.Table) -> (rows: Int, columns: Int) {
        (max(min(model.rows.count, grid.rowY.count - 1), 0), max(min(model.columnCount, grid.columnX.count - 1), 0))
    }

    /// The number of cells that `accessibilityTable` makes.
    private static func accessibilityCellCount(_ model: TranscriptTable, grid: BlockLayout.Table) -> Int {
        let (rows, columns) = accessibilityGridSize(model, grid: grid)
        return model.rows.prefix(rows).reduce(0) { $0 + min($1.count, columns) }
    }

    /// Which items the layout has and where they are, found without
    /// reading the text of its blocks.
    var accessibilityGeometry: AccessibilityGeometry {
        var entries: [AccessibilityGeometry.Entry] = []
        entries.reserveCapacity(entryCount)
        for index in 0..<entryCount {
            let entry = entry(at: index)
            let block = entry.layout.block
            let elements: Int
            if let model = block.kind.table, let grid = entry.layout.table {
                elements = Self.accessibilityCellCount(model, grid: grid)
            } else {
                elements = block.text.isEmpty && block.kind != .rule ? 0 : 1
            }
            entries.append(.init(id: block.id, elements: elements, frame: entry.frame))
        }
        return AccessibilityGeometry(entries: entries, hasRemainder: hasAccessibilityRemainder)
    }

    /// Whether the text that a line limit leaves out gets an item of its
    /// own, after the items of the blocks shown. It does when no block shown
    /// has an item, or when the last one that has an item is a table.
    var hasAccessibilityRemainder: Bool {
        guard leavesTextOut, entryCount < document.count,
              (entryCount..<document.count).contains(where: { AccessibilityText.hasItem(document.block(at: $0)) }) else {
            return false
        }
        for index in (0..<entryCount).reversed() {
            let entry = entry(at: index)
            if let model = entry.layout.block.kind.table, let grid = entry.layout.table {
                if Self.accessibilityCellCount(model, grid: grid) > 0 { return true }
            } else if AccessibilityText.hasItem(entry.layout.block) {
                return false
            }
        }
        return true
    }
}

/// The blocks of a layout, with the number of elements and the frame of
/// each, and whether the text that a line limit leaves out has an item.
struct AccessibilityGeometry: Equatable {
    struct Entry: Equatable {
        let id: String
        /// 0 for a block without an item, the number of cells for a table,
        /// and 1 for other blocks.
        let elements: Int
        let frame: CGRect
    }

    let entries: [Entry]
    /// See `DocumentLayout.hasAccessibilityRemainder`.
    let hasRemainder: Bool

    /// Whether the two have the same elements, wherever they are.
    func hasSameElements(as other: AccessibilityGeometry) -> Bool {
        hasRemainder == other.hasRemainder && entries.count == other.entries.count
            && zip(entries, other.entries).allSatisfy { $0.id == $1.id && $0.elements == $1.elements }
    }
}

/// Decides when assistive technologies must hear that the layout changed.
///
/// A layout that only adds text to the end of the one before needs a
/// layout-changed notification only when elements come or go. Other
/// layouts, such as the ones that a new width or an image start, need it
/// also when an element moved or changed its size. A layout that only gives
/// code other colors has the same geometry, so it needs none.
struct AccessibilityLayoutWatch {
    /// The geometry of the layout installed last.
    private(set) var geometry: AccessibilityGeometry?

    /// Takes in a layout that was installed, and tells whether it needs a
    /// notification.
    mutating func install(_ layout: DocumentLayout, isAppend: Bool) -> Bool {
        let new = layout.accessibilityGeometry
        defer { geometry = new }
        guard let old = geometry else { return true }
        return isAppend ? !new.hasSameElements(as: old) : new != old
    }

    /// Starts from `layout`, whose elements assistive technologies just got.
    mutating func start(with layout: DocumentLayout) {
        geometry = layout.accessibilityGeometry
    }
}

/// The words of the blocks that items were last made for. A block whose
/// layout is the same object as before keeps its words, so a long
/// transcript is not read again for each layout while text streams in. Use
/// one instance with one `math` only, on one thread at a time.
final class AccessibilityWords {
    struct Words {
        let text: String
        let links: [AccessibilityItem.Link]
        /// For a table: each cell's words.
        let cells: [Words]
    }

    private struct Kept {
        let layout: BlockLayout
        let words: Words
    }

    private var kept: [AccessibilityItem.Key: Kept] = [:]
    private var next: [AccessibilityItem.Key: Kept] = [:]
    private var definitions: [String: String] = [:]

    /// Starts a new set of items. Other link definitions can change the
    /// links of any block, so then no words are used again.
    func begin(definitions: [String: String]) {
        if definitions != self.definitions {
            kept = [:]
            self.definitions = definitions
        }
        next = [:]
    }

    func words(for key: AccessibilityItem.Key, layout: BlockLayout) -> Words? {
        kept[key].flatMap { $0.layout === layout ? $0.words : nil }
    }

    func keep(_ words: Words, for key: AccessibilityItem.Key, layout: BlockLayout) {
        next[key] = Kept(layout: layout, words: words)
    }

    /// Keeps only the words of the blocks in the last set of items.
    func end() {
        kept = next
        next = [:]
    }
}

/// The words that assistive technologies get for a block.
enum AccessibilityText {
    /// The block's text in `range`, with images as their alt text and
    /// formulas as `math` gives them, in place of the U+FFFC character each
    /// stands for.
    static func readable(_ block: TranscriptBlock, in range: Range<Int>, math: (TranscriptMath) -> String = \.tex) -> String {
        readable(block, in: range, spans: block.spans, math: math)
    }

    /// - Parameter spans: the spans of the block that can start in
    ///   `range`, in the block's order.
    static func readable(_ block: TranscriptBlock, in range: Range<Int>, spans: some BidirectionalCollection<InlineSpan>,
                         math: (TranscriptMath) -> String) -> String {
        let text = NSMutableString(string: (block.text as NSString).substring(with: NSRange(location: range.lowerBound,
                                                                                          length: range.count)))
        for span in spans.reversed() where range.contains(span.range.lowerBound) && span.range.count == 1 {
            guard let replacement = span.image?.alt ?? span.math.map(math) else { continue }
            text.replaceCharacters(in: NSRange(location: span.range.lowerBound - range.lowerBound, length: 1), with: replacement)
        }
        return text as String
    }

    /// Whether a block that is not a table gets an item: it has text, or it
    /// is a rule.
    static func hasItem(_ block: TranscriptBlock) -> Bool {
        !readable(block, in: 0..<block.utf16Count).isEmpty || block.kind == .rule
    }

    /// What VoiceOver says for a block: its list marker, then its text.
    static func spoken(_ text: String, of block: TranscriptBlock) -> String {
        switch block.marker {
        case .task(let checked)?:
            let state = checked
                ? NSLocalizedString("Checked", comment: "VoiceOver: a task list item that is done")
                : NSLocalizedString("Unchecked", comment: "VoiceOver: a task list item that is not done")
            return state + ", " + text
        case .number(let number)?:
            return number + " " + text
        case .bullet?, nil:
            if case .rule = block.kind {
                return NSLocalizedString("Separator", comment: "VoiceOver: a thematic break between blocks")
            }
            return text
        }
    }

    /// A list item's position and the number of items in its list.
    static func position(_ position: ListPosition) -> String {
        let format = NSLocalizedString("Item %1$ld of %2$ld",
                                       comment: "VoiceOver: a list item's position in its list (%1$ld) and the number of items in the list (%2$ld)")
        return String(format: format, position.index, position.count)
    }

    /// The links that start in `range` of the block's text.
    static func links(of block: TranscriptBlock, in range: Range<Int>, math: (TranscriptMath) -> String = \.tex,
                      definitions: [String: String]) -> [AccessibilityItem.Link] {
        links(of: block, in: range, spans: block.spans, math: math, definitions: definitions)
    }

    /// - Parameter spans: the spans of the block that can start in
    ///   `range`, in the block's order.
    static func links(of block: TranscriptBlock, in range: Range<Int>, spans: some BidirectionalCollection<InlineSpan>,
                      math: (TranscriptMath) -> String, definitions: [String: String]) -> [AccessibilityItem.Link] {
        var links: [AccessibilityItem.Link] = []
        for span in spans where range.contains(span.range.lowerBound) {
            guard let target = span.link ?? span.reference.flatMap({ definitions[$0] }), let url = URL(string: target) else {
                continue
            }
            let end = min(span.range.upperBound, block.utf16Count)
            links.append(.init(title: readable(block, in: span.range.lowerBound..<end, spans: spans, math: math), url: url))
        }
        return links
    }

    /// The spans of `block` that start in each of `ranges`, in the block's
    /// order. Each span goes to the range that holds its start, found by
    /// binary search, so a table costs its spans, not its spans times its
    /// cells.
    static func spans(of block: TranscriptBlock, startingIn ranges: [Range<Int>]) -> [[InlineSpan]] {
        var result = Array(repeating: [InlineSpan](), count: ranges.count)
        // An empty range before a range with the same start: the range with text comes last.
        let order = ranges.indices.sorted { (ranges[$0].lowerBound, ranges[$0].upperBound) < (ranges[$1].lowerBound, ranges[$1].upperBound) }
        for span in block.spans {
            let start = span.range.lowerBound
            var low = 0
            var high = order.count
            while low < high {
                let middle = (low + high) / 2
                if ranges[order[middle]].lowerBound <= start { low = middle + 1 } else { high = middle }
            }
            guard low > 0, ranges[order[low - 1]].contains(start) else { continue }
            result[order[low - 1]].append(span)
        }
        return result
    }

    struct ListPosition: Equatable {
        /// From 1.
        let index: Int
        let count: Int
    }

    /// The position of each list item's first block among the first `end`
    /// blocks, by block index. The count takes in every item of the list,
    /// also the items after `end`.
    ///
    /// A list is a run of items at one depth, in the same containers, with
    /// the item's content in between. It ends at a block outside those
    /// containers, or at an item with another kind of marker: bullets and
    /// task boxes go together, and numbers go with numbers that have the
    /// same delimiter.
    static func listPositions(in document: TranscriptDocument, upTo end: Int) -> [Int: ListPosition] {
        struct Run {
            /// The index of the list item container of the list's items.
            let depth: Int
            let containers: ArraySlice<TranscriptBlock.Container>
            let kind: Character
            var items: [Int] = []
        }
        var positions: [Int: ListPosition] = [:]
        var runs: [Run] = []
        func close(_ run: Run) {
            guard run.items.first.map({ $0 < end }) ?? false else { return }
            for (position, item) in run.items.enumerated() where item < end {
                positions[item] = ListPosition(index: position + 1, count: run.items.count)
            }
        }
        for index in 0..<document.count {
            let block = document.block(at: index)
            while let run = runs.last,
                  !(block.containers.count > run.depth && block.containers[...run.depth] == run.containers) {
                close(runs.removeLast())
            }
            if index >= end, runs.isEmpty { break }
            guard let marker = block.marker, let depth = block.containers.lastIndex(of: .listItem) else { continue }
            let kind: Character
            switch marker {
            case .bullet, .task: kind = "-"
            case .number(let number): kind = number.last ?? "."
            }
            if let run = runs.last, run.depth == depth {
                if run.kind == kind {
                    runs[runs.count - 1].items.append(index)
                    continue
                }
                close(runs.removeLast())
            }
            runs.append(Run(depth: depth, containers: block.containers[...depth], kind: kind, items: [index]))
        }
        runs.forEach(close)
        return positions
    }
}

extension TranscriptBlock.Kind {
    var isHeading: Bool {
        if case .heading = self { return true }
        return false
    }
}
