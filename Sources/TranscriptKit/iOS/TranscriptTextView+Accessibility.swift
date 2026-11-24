#if canImport(UIKit) && !os(watchOS)
import UIKit

/// One accessibility element for each block: VoiceOver reads the text block
/// by block, finds headings with the rotor, and opens links as actions.
extension TranscriptTextView {
    /// The elements for `layout`, made again only when the layout changes.
    func accessibilityElements(for layout: DocumentLayout) -> [UIAccessibilityElement] {
        if let cached = accessibilityCache, cached.layout === layout { return cached.elements }
        var elements: [UIAccessibilityElement] = []
        for item in layout.accessibilityItems() {
            let element = UIAccessibilityElement(accessibilityContainer: self)
            element.accessibilityLabel = item.label
            element.accessibilityFrameInContainerSpace = item.frame
            var traits: UIAccessibilityTraits = .staticText
            if item.isHeading { traits.insert(.header) }
            let format = NSLocalizedString("Open %@", comment: "VoiceOver action that opens a link; %@ is the link's text")
            let actions = item.links.map { link in
                UIAccessibilityCustomAction(name: String(format: format, link.title)) { [weak self] _ in
                    self?.openLink(link.url)
                    return true
                }
            }
            if !actions.isEmpty { traits.insert(.link) }
            element.accessibilityTraits = traits
            element.accessibilityCustomActions = actions
            elements.append(element)
        }
        accessibilityCache = AccessibilityCache(layout: layout, elements: elements)
        return elements
    }
}

final class AccessibilityCache {
    let layout: DocumentLayout
    let elements: [UIAccessibilityElement]

    init(layout: DocumentLayout, elements: [UIAccessibilityElement]) {
        self.layout = layout
        self.elements = elements
    }
}
#endif
