#if canImport(UIKit) && !os(watchOS)
import UIKit

/// One accessibility element for each block: VoiceOver reads the text block
/// by block, finds headings with the rotor, and opens links as actions.
extension TranscriptTextView {
    /// The elements for `layout`, brought up to date only when the layout
    /// changes. A block keeps its element from one layout to the next, so
    /// VoiceOver focus stays where it is while text streams in.
    func accessibilityElements(for layout: DocumentLayout) -> [UIAccessibilityElement] {
        let cache = accessibilityCache ?? AccessibilityCache()
        accessibilityCache = cache
        if cache.layout === layout { return cache.elements }
        var byKey: [String: BlockAccessibilityElement] = [:]
        var elements: [UIAccessibilityElement] = []
        for item in layout.accessibilityItems() {
            let element = cache.byKey[item.key] ?? BlockAccessibilityElement(accessibilityContainer: self)
            element.update(with: item) { [weak self] url in self?.openLink(url) }
            byKey[item.key] = element
            elements.append(element)
        }
        cache.layout = layout
        cache.shape = layout.accessibilityShape
        cache.byKey = byKey
        cache.elements = elements
        return elements
    }

    /// Tells assistive technologies that elements came or went, or moved,
    /// after `layout` was installed. Elements keep their identity, so VoiceOver
    /// focus stays on its block. Nothing is posted before an assistive
    /// technology has asked for the elements, or when an update only adds
    /// text to the last block.
    func postAccessibilityLayoutChangeIfNeeded(for layout: DocumentLayout, isAppend: Bool) {
        guard let cache = accessibilityCache, cache.layout != nil, window != nil else { return }
        let shape = layout.accessibilityShape
        guard !isAppend || shape != cache.shape else { return }
        cache.shape = shape
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
    }
}

/// A block's element. Its block's id keeps it from one layout to the next.
final class BlockAccessibilityElement: UIAccessibilityElement {
    private var links: [AccessibilityItem.Link]?

    func update(with item: AccessibilityItem, openLink: @escaping (URL) -> Void) {
        if accessibilityLabel != item.label { accessibilityLabel = item.label }
        if accessibilityFrameInContainerSpace != item.frame { accessibilityFrameInContainerSpace = item.frame }
        var traits: UIAccessibilityTraits = .staticText
        if item.isHeading { traits.insert(.header) }
        if !item.links.isEmpty { traits.insert(.link) }
        if accessibilityTraits != traits { accessibilityTraits = traits }
        guard links != item.links else { return }
        links = item.links
        let format = NSLocalizedString("Open %@", comment: "VoiceOver action that opens a link; %@ is the link's text")
        accessibilityCustomActions = item.links.map { link in
            UIAccessibilityCustomAction(name: String(format: format, link.title)) { _ in
                openLink(link.url)
                return true
            }
        }
    }
}

final class AccessibilityCache {
    /// The layout that the elements were last brought up to date for.
    var layout: DocumentLayout?
    /// The shape of the layout that assistive technologies last heard about.
    var shape: AccessibilityShape?
    var byKey: [String: BlockAccessibilityElement] = [:]
    var elements: [UIAccessibilityElement] = []
}
#endif
