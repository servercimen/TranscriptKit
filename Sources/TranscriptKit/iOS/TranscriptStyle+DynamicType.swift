#if canImport(UIKit) && !os(watchOS)
import UIKit

extension TranscriptStyle {
    /// A copy with every text size and line height scaled for `category`, as
    /// `UIFontMetrics` scales body text. Spacing and indents do not change.
    /// `TranscriptText` applies it when `scalesWithDynamicType` is on. With
    /// `TranscriptTextView`, set the scaled style yourself when the trait
    /// collection's `preferredContentSizeCategory` changes.
    public func scaled(for category: UIContentSizeCategory) -> TranscriptStyle {
        let metrics = UIFontMetrics(forTextStyle: .body)
        let traits = UITraitCollection(preferredContentSizeCategory: category)
        let scale = { (size: CGFloat) in metrics.scaledValue(for: size, compatibleWith: traits) }
        var copy = self
        copy.bodySize = scale(bodySize)
        copy.bodyFont = bodyFont?.scaled(scale)
        copy.headingFonts = headingFonts.map { $0.scaled(scale) }
        copy.codeFont = codeFont?.scaled(scale)
        return copy
    }
}
#endif
