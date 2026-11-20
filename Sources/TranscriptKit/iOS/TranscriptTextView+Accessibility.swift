#if canImport(UIKit) && !os(watchOS)
import UIKit

/// One accessibility element for each block: VoiceOver reads the text block
/// by block, finds headings with the rotor, and opens links as actions.
extension TranscriptTextView {
    /// The elements for `layout`, made again only when the layout changes.
    func accessibilityElements(for layout: DocumentLayout) -> [UIAccessibilityElement] {
        if let cached = accessibilityCache, cached.layout === layout { return cached.elements }
        var elements: [UIAccessibilityElement] = []
        let definitions = layout.document.linkDefinitions
        for index in 0..<layout.entryCount {
            let entry = layout.entry(at: index)
            let block = entry.layout.block
            let text = Self.readableText(of: block, upTo: min(entry.layout.length, block.utf16Count))
            if text.isEmpty, block.kind != .rule { continue }
            let element = UIAccessibilityElement(accessibilityContainer: self)
            element.accessibilityLabel = Self.spokenText(text, of: block)
            element.accessibilityFrameInContainerSpace = entry.frame
            var traits: UIAccessibilityTraits = .staticText
            if case .heading = block.kind { traits.insert(.header) }
            var actions: [UIAccessibilityCustomAction] = []
            let shown = min(entry.layout.length, block.utf16Count)
            let original = block.text as NSString
            for span in block.spans where span.range.upperBound <= shown {
                guard let target = span.link ?? span.reference.flatMap({ definitions[$0] }), let url = URL(string: target) else {
                    continue
                }
                let title = original.substring(with: NSRange(location: span.range.lowerBound, length: span.range.count))
                let format = NSLocalizedString("Open %@", comment: "VoiceOver action that opens a link; %@ is the link's text")
                actions.append(UIAccessibilityCustomAction(name: String(format: format, title)) { [weak self] _ in
                    self?.openLink(url)
                    return true
                })
            }
            if !actions.isEmpty { traits.insert(.link) }
            element.accessibilityTraits = traits
            element.accessibilityCustomActions = actions
            elements.append(element)
        }
        accessibilityCache = AccessibilityCache(layout: layout, elements: elements)
        return elements
    }

    /// A block's text with images as their alt text and formulas as their
    /// LaTeX, in place of the U+FFFC character each stands for.
    static func readableText(of block: TranscriptBlock, upTo end: Int) -> String {
        let text = NSMutableString(string: (block.text as NSString).substring(to: end))
        for span in block.spans.reversed() where span.range.lowerBound < end && span.range.count == 1 {
            guard let replacement = span.image?.alt ?? span.math?.tex else { continue }
            text.replaceCharacters(in: NSRange(location: span.range.lowerBound, length: 1), with: replacement)
        }
        return text as String
    }

    /// What VoiceOver says for a block: its list marker, then its text.
    static func spokenText(_ text: String, of block: TranscriptBlock) -> String {
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
