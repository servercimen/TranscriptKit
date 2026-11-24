#if canImport(UIKit) && !os(watchOS)
import UIKit

/// One accessibility element for each block: VoiceOver reads the text block
/// by block, finds headings with the rotor, and opens links as actions. A
/// list item tells its position in its list, and a table is a data table
/// with one element for each cell.
extension TranscriptTextView {
    /// The elements for `layout`, brought up to date only when the layout
    /// changes. A block keeps its element from one layout to the next, so
    /// VoiceOver focus stays where it is while text streams in.
    func accessibilityElements(for layout: DocumentLayout) -> [UIAccessibilityElement] {
        let cache = accessibilityCache ?? AccessibilityCache()
        accessibilityCache = cache
        if cache.layout === layout { return cache.elements }
        var byKey: [String: UIAccessibilityElement] = [:]
        var elements: [UIAccessibilityElement] = []
        for item in layout.accessibilityItems(math: mathAccessibilityLabel ?? \.tex) {
            let element: UIAccessibilityElement
            if let table = item.table {
                let tableElement = cache.byKey[item.key] as? TableAccessibilityElement
                    ?? TableAccessibilityElement(accessibilityContainer: self)
                tableElement.update(frame: item.frame, table: table, in: self)
                element = tableElement
            } else {
                let blockElement = cache.byKey[item.key] as? BlockAccessibilityElement
                    ?? BlockAccessibilityElement(accessibilityContainer: self)
                blockElement.update(with: item, in: self)
                element = blockElement
            }
            byKey[item.key] = element
            elements.append(element)
        }
        cache.layout = layout
        cache.shape = layout.accessibilityShape
        cache.byKey = byKey
        cache.elements = elements
        return elements
    }

    /// Makes the elements again on the next request, for example with new
    /// words for formulas.
    func invalidateAccessibilityElements() {
        guard let cache = accessibilityCache, cache.layout != nil else { return }
        cache.layout = nil
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
    }

    /// Tells assistive technologies that elements came or went, or moved,
    /// after `layout` was installed. Elements keep their identity, so
    /// VoiceOver focus stays on its block. Nothing is posted before an
    /// assistive technology has asked for the elements, or when an update
    /// only adds text to the last block.
    func postAccessibilityLayoutChangeIfNeeded(for layout: DocumentLayout, isAppend: Bool) {
        guard let cache = accessibilityCache, cache.layout != nil, window != nil else { return }
        let shape = layout.accessibilityShape
        guard !isAppend || shape != cache.shape else { return }
        cache.shape = shape
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
    }
}

/// The text and frame of a block or a table cell. Assistive technologies
/// can ask for them from any thread, so they are kept here, and the
/// getters read them on the main thread (see `onMainThread`).
class TextAccessibilityElement: UIAccessibilityElement {
    private var label: String?
    private var value: String?
    private var traits: UIAccessibilityTraits = .staticText
    /// The element in the view's coordinates.
    private(set) var frameInView: CGRect = .zero
    private weak var view: TranscriptTextView?
    private var links: [AccessibilityItem.Link]?
    private var actions: [UIAccessibilityCustomAction]?

    func update(label: String, value: String?, isHeading: Bool, frame: CGRect, links: [AccessibilityItem.Link],
                in view: TranscriptTextView) {
        self.label = label
        self.value = value
        frameInView = frame
        self.view = view
        var traits: UIAccessibilityTraits = .staticText
        if isHeading { traits.insert(.header) }
        if !links.isEmpty { traits.insert(.link) }
        self.traits = traits
        guard self.links != links else { return }
        self.links = links
        let format = NSLocalizedString("Open %@", comment: "VoiceOver action that opens a link; %@ is the link's text")
        actions = links.map { link in
            UIAccessibilityCustomAction(name: String(format: format, link.title)) { @Sendable [weak view] _ in
                onMainThread { view?.openLink(link.url) }
                return true
            }
        }
    }

    nonisolated override var accessibilityLabel: String? {
        get { onMainThread { label } }
        set { onMainThread { label = newValue } }
    }

    nonisolated override var accessibilityValue: String? {
        get { onMainThread { value } }
        set { onMainThread { value = newValue } }
    }

    nonisolated override var accessibilityTraits: UIAccessibilityTraits {
        get { onMainThread { traits } }
        set { onMainThread { traits = newValue } }
    }

    /// From the view: a table cell's container is the table's element, not a view.
    nonisolated override var accessibilityFrame: CGRect {
        get { onMainThread { view.map { UIAccessibility.convertToScreenCoordinates(frameInView, in: $0) } ?? .zero } }
        set {}
    }

    nonisolated override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get { onMainThread { actions } }
        set { onMainThread { actions = newValue } }
    }
}

/// A block's element. Its block's id keeps it from one layout to the next.
final class BlockAccessibilityElement: TextAccessibilityElement {
    func update(with item: AccessibilityItem, in view: TranscriptTextView) {
        update(label: item.label, value: item.value, isHeading: item.isHeading, frame: item.frame, links: item.links, in: view)
    }
}

/// A table's element: a data table that holds one element for each cell,
/// so VoiceOver reads the table cell by cell, with the row and column.
final class TableAccessibilityElement: UIAccessibilityElement, UIAccessibilityContainerDataTable {
    private var cells: [CellAccessibilityElement] = []
    private var rowCount = 0
    private var columnCount = 0
    private var frameInView: CGRect = .zero
    private weak var view: TranscriptTextView?

    func update(frame: CGRect, table: AccessibilityItem.Table, in view: TranscriptTextView) {
        frameInView = frame
        self.view = view
        rowCount = table.rowCount
        columnCount = table.columnCount
        var cells: [CellAccessibilityElement] = []
        for (index, cell) in table.cells.enumerated() {
            let element = index < self.cells.count && self.cells[index].row == cell.row && self.cells[index].column == cell.column
                ? self.cells[index] : CellAccessibilityElement(accessibilityContainer: self)
            element.update(with: cell, in: view)
            cells.append(element)
        }
        self.cells = cells
    }

    nonisolated override var isAccessibilityElement: Bool {
        get { false }
        set {}
    }

    nonisolated override var accessibilityContainerType: UIAccessibilityContainerType {
        get { .dataTable }
        set {}
    }

    nonisolated override var accessibilityElements: [Any]? {
        get { onMainThread { cells } }
        set {}
    }

    nonisolated override var accessibilityFrame: CGRect {
        get { onMainThread { view.map { UIAccessibility.convertToScreenCoordinates(frameInView, in: $0) } ?? .zero } }
        set {}
    }

    nonisolated func accessibilityDataTableCellElement(forRow row: Int, column: Int) -> (any UIAccessibilityContainerDataTableCell)? {
        onMainThread { cells.first { $0.row == row && $0.column == column } }
    }

    nonisolated func accessibilityRowCount() -> Int { onMainThread { rowCount } }

    nonisolated func accessibilityColumnCount() -> Int { onMainThread { columnCount } }

    nonisolated func accessibilityHeaderElements(forColumn column: Int) -> [any UIAccessibilityContainerDataTableCell]? {
        onMainThread { cells.first { $0.row == 0 && $0.column == column }.map { [$0] } }
    }
}

/// A table cell's element.
final class CellAccessibilityElement: TextAccessibilityElement, UIAccessibilityContainerDataTableCell {
    private(set) var row = -1
    private(set) var column = -1

    func update(with cell: AccessibilityItem.Table.Cell, in view: TranscriptTextView) {
        row = cell.row
        column = cell.column
        update(label: cell.label, value: nil, isHeading: false, frame: cell.frame, links: cell.links, in: view)
    }

    nonisolated func accessibilityRowRange() -> NSRange { onMainThread { NSRange(location: row, length: 1) } }

    nonisolated func accessibilityColumnRange() -> NSRange { onMainThread { NSRange(location: column, length: 1) } }
}

final class AccessibilityCache {
    /// The layout that the elements were last brought up to date for.
    var layout: DocumentLayout?
    /// The shape of the layout that assistive technologies last heard about.
    var shape: AccessibilityShape?
    var byKey: [String: UIAccessibilityElement] = [:]
    var elements: [UIAccessibilityElement] = []
}
#endif
