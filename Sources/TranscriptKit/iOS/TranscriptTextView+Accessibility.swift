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
        let openLink: (URL) -> Void = { [weak self] url in self?.openLink(url) }
        for item in layout.accessibilityItems(math: mathAccessibilityLabel ?? \.tex) {
            let element: UIAccessibilityElement
            if let table = item.table {
                let tableElement = cache.byKey[item.key] as? TableAccessibilityElement
                    ?? TableAccessibilityElement(accessibilityContainer: self)
                tableElement.update(frame: item.frame, table: table, in: self, openLink: openLink)
                element = tableElement
            } else {
                let blockElement = cache.byKey[item.key] as? BlockAccessibilityElement
                    ?? BlockAccessibilityElement(accessibilityContainer: self)
                blockElement.update(with: item, openLink: openLink)
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

private func traits(heading: Bool, links: Bool) -> UIAccessibilityTraits {
    var traits: UIAccessibilityTraits = .staticText
    if heading { traits.insert(.header) }
    if links { traits.insert(.link) }
    return traits
}

@MainActor
private func actions(for links: [AccessibilityItem.Link], openLink: @escaping (URL) -> Void) -> [UIAccessibilityCustomAction] {
    let format = NSLocalizedString("Open %@", comment: "VoiceOver action that opens a link; %@ is the link's text")
    return links.map { link in
        UIAccessibilityCustomAction(name: String(format: format, link.title)) { _ in
            openLink(link.url)
            return true
        }
    }
}

/// A block's element. Its block's id keeps it from one layout to the next.
final class BlockAccessibilityElement: UIAccessibilityElement {
    private var links: [AccessibilityItem.Link]?

    func update(with item: AccessibilityItem, openLink: @escaping (URL) -> Void) {
        if accessibilityLabel != item.label { accessibilityLabel = item.label }
        if accessibilityValue != item.value { accessibilityValue = item.value }
        if accessibilityFrameInContainerSpace != item.frame { accessibilityFrameInContainerSpace = item.frame }
        let traits = traits(heading: item.isHeading, links: !item.links.isEmpty)
        if accessibilityTraits != traits { accessibilityTraits = traits }
        guard links != item.links else { return }
        links = item.links
        accessibilityCustomActions = actions(for: item.links, openLink: openLink)
    }
}

/// A table's element: a data table that holds one element for each cell,
/// so VoiceOver reads the table cell by cell, with the row and column.
final class TableAccessibilityElement: UIAccessibilityElement, UIAccessibilityContainerDataTable {
    private var cells: [CellAccessibilityElement] = []
    private var rowCount = 0
    private var columnCount = 0

    override init(accessibilityContainer container: Any) {
        super.init(accessibilityContainer: container)
        isAccessibilityElement = false
        accessibilityContainerType = .dataTable
    }

    func update(frame: CGRect, table: AccessibilityItem.Table, in view: TranscriptTextView, openLink: @escaping (URL) -> Void) {
        if accessibilityFrameInContainerSpace != frame { accessibilityFrameInContainerSpace = frame }
        rowCount = table.rowCount
        columnCount = table.columnCount
        var cells: [CellAccessibilityElement] = []
        for (index, cell) in table.cells.enumerated() {
            let element = index < self.cells.count && self.cells[index].row == cell.row && self.cells[index].column == cell.column
                ? self.cells[index] : CellAccessibilityElement(accessibilityContainer: self)
            element.update(with: cell, in: view, openLink: openLink)
            cells.append(element)
        }
        if cells.count != self.cells.count || zip(cells, self.cells).contains(where: { $0 !== $1 }) {
            self.cells = cells
            accessibilityElements = cells
        }
    }

    func accessibilityDataTableCellElement(forRow row: Int, column: Int) -> (any UIAccessibilityContainerDataTableCell)? {
        cells.first { $0.row == row && $0.column == column }
    }

    func accessibilityRowCount() -> Int { rowCount }

    func accessibilityColumnCount() -> Int { columnCount }

    func accessibilityHeaderElements(forColumn column: Int) -> [any UIAccessibilityContainerDataTableCell]? {
        cells.first { $0.row == 0 && $0.column == column }.map { [$0] }
    }
}

/// A table cell's element.
final class CellAccessibilityElement: UIAccessibilityElement, UIAccessibilityContainerDataTableCell {
    private(set) var row = -1
    private(set) var column = -1
    /// The cell in the view's coordinates.
    private var frameInView: CGRect = .zero
    private weak var view: UIView?
    private var links: [AccessibilityItem.Link]?

    func update(with cell: AccessibilityItem.Table.Cell, in view: UIView, openLink: @escaping (URL) -> Void) {
        row = cell.row
        column = cell.column
        frameInView = cell.frame
        self.view = view
        if accessibilityLabel != cell.label { accessibilityLabel = cell.label }
        let traits = traits(heading: false, links: !cell.links.isEmpty)
        if accessibilityTraits != traits { accessibilityTraits = traits }
        guard links != cell.links else { return }
        links = cell.links
        accessibilityCustomActions = actions(for: cell.links, openLink: openLink)
    }

    /// From the view, because the container is the table's element and not a view.
    override var accessibilityFrame: CGRect {
        get { view.map { UIAccessibility.convertToScreenCoordinates(frameInView, in: $0) } ?? .zero }
        set {}
    }

    func accessibilityRowRange() -> NSRange { NSRange(location: row, length: 1) }

    func accessibilityColumnRange() -> NSRange { NSRange(location: column, length: 1) }
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
