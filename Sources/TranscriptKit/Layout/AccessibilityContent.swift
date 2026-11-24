import CoreGraphics
import Foundation

/// What assistive technologies get for one block on screen. It is made from
/// a layout without UIKit, so that it can be tested on macOS.
struct AccessibilityItem: Equatable {
    struct Link: Equatable {
        let title: String
        let url: URL
    }

    let frame: CGRect
    /// What VoiceOver says: the list marker, then the text.
    let label: String
    let isHeading: Bool
    /// The links in the text. Each is an action that opens it.
    let links: [Link]
}

extension DocumentLayout {
    /// One item for each block on screen that has text, in reading order.
    ///
    /// Under a line limit, the last item holds all of its block's text and
    /// the text of the blocks that the limit leaves out, as a label that is
    /// cut short still reads all of its text.
    func accessibilityItems() -> [AccessibilityItem] {
        var items: [AccessibilityItem] = []
        let definitions = document.linkDefinitions
        for index in 0..<entryCount {
            let entry = entry(at: index)
            let block = entry.layout.block
            let all = 0..<block.utf16Count
            let text = AccessibilityText.readable(block, in: all)
            if text.isEmpty, block.kind != .rule { continue }
            items.append(AccessibilityItem(frame: entry.frame, label: AccessibilityText.spoken(text, of: block),
                                           isHeading: block.kind.isHeading,
                                           links: AccessibilityText.links(of: block, in: all, definitions: definitions)))
        }
        guard leavesTextOut, entryCount < document.count, let last = items.popLast() else { return items }
        var label = last.label
        var links = last.links
        for index in entryCount..<document.count {
            let block = document.block(at: index)
            let all = 0..<block.utf16Count
            let text = AccessibilityText.readable(block, in: all)
            if text.isEmpty, block.kind != .rule { continue }
            label += "\n" + AccessibilityText.spoken(text, of: block)
            links += AccessibilityText.links(of: block, in: all, definitions: definitions)
        }
        items.append(AccessibilityItem(frame: last.frame, label: label, isHeading: last.isHeading, links: links))
        return items
    }
}

/// The words that assistive technologies get for a block.
enum AccessibilityText {
    /// The block's text in `range`, with images as their alt text and
    /// formulas as their LaTeX, in place of the U+FFFC character each
    /// stands for.
    static func readable(_ block: TranscriptBlock, in range: Range<Int>) -> String {
        let text = NSMutableString(string: (block.text as NSString).substring(with: NSRange(location: range.lowerBound,
                                                                                          length: range.count)))
        for span in block.spans.reversed() where range.contains(span.range.lowerBound) && span.range.count == 1 {
            guard let replacement = span.image?.alt ?? span.math?.tex else { continue }
            text.replaceCharacters(in: NSRange(location: span.range.lowerBound - range.lowerBound, length: 1), with: replacement)
        }
        return text as String
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

    /// The links that start in `range` of the block's text.
    static func links(of block: TranscriptBlock, in range: Range<Int>, definitions: [String: String]) -> [AccessibilityItem.Link] {
        var links: [AccessibilityItem.Link] = []
        for span in block.spans where range.contains(span.range.lowerBound) {
            guard let target = span.link ?? span.reference.flatMap({ definitions[$0] }), let url = URL(string: target) else {
                continue
            }
            let end = min(span.range.upperBound, block.utf16Count)
            links.append(.init(title: readable(block, in: span.range.lowerBound..<end), url: url))
        }
        return links
    }
}

extension TranscriptBlock.Kind {
    var isHeading: Bool {
        if case .heading = self { return true }
        return false
    }
}
