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
    func accessibilityItems(math: (TranscriptMath) -> String = \.tex) -> [AccessibilityItem] {
        var items: [AccessibilityItem] = []
        let definitions = document.linkDefinitions
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
            if let model = block.kind.table, let grid = entry.layout.table {
                let table = Self.accessibilityTable(model, grid: grid, of: block, at: entry.y,
                                                    position: positions[index].map(AccessibilityText.position), math: math,
                                                    definitions: definitions)
                guard !table.cells.isEmpty else { continue }
                items.append(AccessibilityItem(key: key(for: block), frame: entry.frame, label: "", value: nil, isHeading: false,
                                               links: [], table: table))
                continue
            }
            let all = 0..<block.utf16Count
            let text = AccessibilityText.readable(block, in: all, math: math)
            if text.isEmpty, block.kind != .rule { continue }
            items.append(AccessibilityItem(key: key(for: block), frame: entry.frame, label: AccessibilityText.spoken(text, of: block),
                                           value: positions[index].map(AccessibilityText.position),
                                           isHeading: block.kind.isHeading,
                                           links: AccessibilityText.links(of: block, in: all, math: math, definitions: definitions),
                                           table: nil))
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

    private static func accessibilityTable(_ model: TranscriptTable, grid: BlockLayout.Table, of block: TranscriptBlock, at y: CGFloat,
                                           position: String?, math: (TranscriptMath) -> String,
                                           definitions: [String: String]) -> AccessibilityItem.Table {
        var cells: [AccessibilityItem.Table.Cell] = []
        let (rowCount, columnCount) = accessibilityGridSize(model, grid: grid)
        for row in 0..<rowCount {
            for (column, range) in model.rows[row].prefix(columnCount).enumerated() {
                let frame = CGRect(x: grid.columnX[column], y: y + grid.rowY[row], width: grid.columnX[column + 1] - grid.columnX[column],
                                   height: grid.rowY[row + 1] - grid.rowY[row])
                let text = AccessibilityText.readable(block, in: range, math: math)
                let isFirst = cells.isEmpty
                cells.append(.init(row: row, column: column, frame: frame,
                                   label: isFirst ? AccessibilityText.spoken(text, of: block) : text,
                                   value: isFirst ? position : nil,
                                   links: AccessibilityText.links(of: block, in: range, math: math, definitions: definitions)))
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

    /// What decides which items the layout has, found without making them.
    /// A layout that only adds text to the end of another has the same
    /// items as that one, with longer text, if their shapes are equal.
    var accessibilityShape: AccessibilityShape {
        guard entryCount > 0 else {
            return AccessibilityShape(entries: 0, lastHasNoItem: false, lastTableCells: 0, hasRemainder: hasAccessibilityRemainder)
        }
        let block = entry(at: entryCount - 1).layout.block
        return AccessibilityShape(entries: entryCount, lastHasNoItem: block.text.isEmpty && block.kind != .rule,
                                  lastTableCells: block.kind.table?.rows.reduce(0) { $0 + $1.count } ?? 0,
                                  hasRemainder: hasAccessibilityRemainder)
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

struct AccessibilityShape: Equatable {
    let entries: Int
    /// The last block has no text yet, so it has no item.
    let lastHasNoItem: Bool
    /// The number of cells in the last block, if it is a table: a row that
    /// streams in adds elements.
    let lastTableCells: Int
    /// See `DocumentLayout.hasAccessibilityRemainder`.
    let hasRemainder: Bool
}

/// When assistive technologies must hear that the layout changed.
enum AccessibilityLayoutChange {
    /// Whether a new layout needs a layout-changed notification.
    ///
    /// A layout that only adds text to the end of the old one needs it only
    /// when elements come or go, which the shape tells. Other layouts, such
    /// as the ones that a new width or an image start, need it when an item
    /// changed, for example its frame. A layout that only gives code other
    /// colors has the same items, so it needs none.
    ///
    /// - Parameter newItems: the items of the new layout, made only when
    ///   they are needed.
    static func isNeeded(isAppend: Bool, oldShape: AccessibilityShape?, oldItems: [AccessibilityItem],
                         newShape: AccessibilityShape, newItems: () -> [AccessibilityItem]) -> Bool {
        guard let oldShape, oldShape == newShape else { return true }
        return !isAppend && newItems() != oldItems
    }
}

/// The words that assistive technologies get for a block.
enum AccessibilityText {
    /// The block's text in `range`, with images as their alt text and
    /// formulas as `math` gives them, in place of the U+FFFC character each
    /// stands for.
    static func readable(_ block: TranscriptBlock, in range: Range<Int>, math: (TranscriptMath) -> String = \.tex) -> String {
        let text = NSMutableString(string: (block.text as NSString).substring(with: NSRange(location: range.lowerBound,
                                                                                          length: range.count)))
        for span in block.spans.reversed() where range.contains(span.range.lowerBound) && span.range.count == 1 {
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
        var links: [AccessibilityItem.Link] = []
        for span in block.spans where range.contains(span.range.lowerBound) {
            guard let target = span.link ?? span.reference.flatMap({ definitions[$0] }), let url = URL(string: target) else {
                continue
            }
            let end = min(span.range.upperBound, block.utf16Count)
            links.append(.init(title: readable(block, in: span.range.lowerBound..<end, math: math), url: url))
        }
        return links
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
