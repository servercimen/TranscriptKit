import CoreGraphics
import CoreText
import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// How one kind of text is set: its font, letter spacing and line height.
/// See `TranscriptStyle.bodyFont`, `headingFonts` and `codeFont`.
public struct TranscriptFont: Hashable, Sendable {
    /// A PostScript font name, such as "Avenir-Book", or nil for the system font.
    public var name: String?
    public var size: CGFloat
    /// The weight of the system font, from -1 to 1 as `UIFont.Weight`'s raw
    /// values: 0 is regular, 0.23 medium, 0.3 semibold, 0.4 bold. A named
    /// font has its own weight, so this is not used for it.
    public var weight: CGFloat
    /// The monospaced system font, for code. Not used for a named font.
    public var monospaced: Bool
    /// Extra space between characters, in points.
    public var letterSpacing: CGFloat
    /// The height of each line, in points, or nil for the font's own line
    /// height plus `TranscriptStyle.lineSpacing`. A line is never less tall
    /// than the font needs, and its text is centred in the line.
    public var lineHeight: CGFloat?

    public init(name: String? = nil, size: CGFloat, weight: CGFloat = 0, monospaced: Bool = false,
                letterSpacing: CGFloat = 0, lineHeight: CGFloat? = nil) {
        self.name = name
        self.size = size
        self.weight = weight
        self.monospaced = monospaced
        self.letterSpacing = letterSpacing
        self.lineHeight = lineHeight
    }

    /// The font at `size`, or at its own size.
    func makeFont(size: CGFloat? = nil) -> CTFont {
        let size = size ?? self.size
        if let name {
            return CTFontCreateWithName(name as CFString, size, nil)
        }
        #if canImport(UIKit)
        let font = monospaced
            ? UIFont.monospacedSystemFont(ofSize: size, weight: UIFont.Weight(rawValue: weight))
            : UIFont.systemFont(ofSize: size, weight: UIFont.Weight(rawValue: weight))
        return font as CTFont
        #elseif canImport(AppKit)
        let font = monospaced
            ? NSFont.monospacedSystemFont(ofSize: size, weight: NSFont.Weight(rawValue: weight))
            : NSFont.systemFont(ofSize: size, weight: NSFont.Weight(rawValue: weight))
        return font as CTFont
        #else
        return CTFontCreateUIFontForLanguage(monospaced ? .userFixedPitch : .system, size, nil)!
        #endif
    }

    /// The same font with its size and line height passed through `scale`.
    func scaled(_ scale: (CGFloat) -> CGFloat) -> TranscriptFont {
        var copy = self
        copy.size = scale(size)
        copy.lineHeight = lineHeight.map(scale)
        return copy
    }
}
