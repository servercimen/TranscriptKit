import Foundation
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension TranscriptDocument {
    /// What copying `range` puts on the pasteboard, as one item by type
    /// identifier: the plain text of `copyText(in:)`, and the same text as
    /// RTF, with the fonts of `style`, links, strikethrough and underline.
    /// The RTF has no colors, so pasted text takes the colors of the place
    /// it goes to. The system font becomes Helvetica Neue, with the same
    /// size, bold and italic.
    func pasteboardItem(in range: Range<Int>, style: TranscriptStyle) -> [String: Any] {
        let text = Self.withPublicFonts(copiedText(in: range, style: style))
        var item: [String: Any] = [UTType.utf8PlainText.identifier: text.string]
        if let rtf = try? text.data(from: NSRange(location: 0, length: text.length),
                                    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            item[UTType.rtf.identifier] = rtf
        }
        return item
    }

    /// `text` with each font that has a private name (the system fonts,
    /// whose names start with a period) changed to a public font of the
    /// same size and traits. Apps that find a font by its name in the RTF
    /// do not find a private name, and show another font, without bold or
    /// italic.
    static func withPublicFonts(_ text: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        let whole = NSRange(location: 0, length: result.length)
        text.enumerateAttribute(TranscriptStyle.fontKey, in: whole) { value, range, _ in
            guard let value else { return }
            let font = value as! CTFont
            let name = CTFontCopyPostScriptName(font) as String
            guard name.hasPrefix(".") else { return }
            result.addAttribute(TranscriptStyle.fontKey, value: publicFont(like: font), range: range)
        }
        return result
    }

    private static func publicFont(like font: CTFont) -> CTFont {
        let traits = CTFontGetSymbolicTraits(font)
        let size = CTFontGetSize(font)
        if traits.contains(.traitMonoSpace) { return CTFontCreateWithName("Menlo-Regular" as CFString, size, nil) }
        let base = CTFontCreateWithName("HelveticaNeue" as CFString, size, nil)
        let wanted = traits.intersection([.traitBold, .traitItalic])
        guard !wanted.isEmpty else { return base }
        return CTFontCreateCopyWithSymbolicTraits(base, 0, nil, wanted, wanted) ?? base
    }

    /// Styles the spans of `block` in `piece`, which holds the block's text
    /// from UTF-16 offset `start` on: the fonts of bold, italic and code, and
    /// links, strikethrough and underline, with the attributes that other
    /// apps read.
    func styleSpans(of block: TranscriptBlock, from start: Int, in piece: NSMutableAttributedString, style: TranscriptStyle) {
        let length = piece.length
        let spans = block.spans.compactMap { span -> InlineSpan? in
            let lower = min(max(span.range.lowerBound - start, 0), length)
            let upper = min(max(span.range.upperBound - start, 0), length)
            guard lower < upper else { return nil }
            var shifted = span
            shifted.range = lower..<upper
            return shifted
        }
        guard !spans.isEmpty else { return }
        var cuts: Set<Int> = [0, length]
        for span in spans {
            cuts.insert(span.range.lowerBound)
            cuts.insert(span.range.upperBound)
        }
        let sorted = cuts.sorted()
        for (lower, upper) in zip(sorted, sorted.dropFirst()) {
            var traits: InlineSpan.Traits = []
            var link: String?
            for span in spans where span.range.lowerBound <= lower && span.range.upperBound >= upper {
                traits.formUnion(span.traits)
                if let destination = destination(of: span) { link = destination }
            }
            let range = NSRange(location: lower, length: upper - lower)
            if !traits.intersection([.bold, .italic, .code]).isEmpty {
                piece.addAttribute(TranscriptStyle.fontKey, value: style.font(for: block.kind, traits: traits), range: range)
            }
            if traits.contains(.strikethrough) {
                piece.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
            if traits.contains(.underline) {
                piece.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
            if let link, let url = URL(string: link) {
                piece.addAttribute(.link, value: url, range: range)
            }
        }
    }
}
