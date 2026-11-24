import CoreGraphics
import CoreText
import Foundation

/// Where lines sit in their column; see `TranscriptStyle.textAlignment`.
public enum TranscriptTextAlignment: Hashable, Sendable {
    case leading
    case center
    case trailing
}

/// How a list item's number is written; see `TranscriptStyle.listNumberFormat`.
public enum TranscriptListNumberFormat: Hashable, Sendable {
    /// The number, then "." or ")" as the Markdown wrote it.
    case asWritten
    /// The number between `prefix` and `suffix`, such as "(" and ")".
    case custom(prefix: String, suffix: String)

    /// The number, then ".", whatever the Markdown wrote.
    public static let period = custom(prefix: "", suffix: ".")
    /// The number, then ")", whatever the Markdown wrote.
    public static let parenthesis = custom(prefix: "", suffix: ")")

    /// The text of the marker that the Markdown wrote as `written`, such as "3.".
    func text(for written: String) -> String {
        guard case .custom(let prefix, let suffix) = self else { return written }
        let number = written.prefix { $0.isASCII && $0.isNumber }
        return prefix + number + suffix
    }
}

/// Typography and spacing for a transcript.
public struct TranscriptStyle: Equatable, Sendable {
    /// The font of paragraphs, list items, quotes and tables. Nil uses the
    /// system font at `bodySize`.
    public var bodyFont: TranscriptFont?
    /// The fonts of headings: the first for level 1, the second for level 2,
    /// and so on. Levels past the end use the last one. Empty uses the
    /// emphasized system font at 1.5, 1.3 and 1.15 times `bodySize`.
    public var headingFonts: [TranscriptFont] = []
    /// The font of code blocks, and the design of inline code, which is set at
    /// 0.9 times the size of the text around it. Nil uses the system's
    /// monospaced font at 0.88 times `bodySize`.
    public var codeFont: TranscriptFont?
    /// Whether `TranscriptText` scales the sizes with Dynamic Type; see
    /// `scaled(for:)`.
    public var scalesWithDynamicType = false
    /// Whether the view sets the text heavier when the Bold Text setting is
    /// on. On by default. Regular text becomes semibold, and bold text
    /// becomes heavy. A named font, such as "Avenir-Book", keeps its own
    /// weight. The default code font takes its bold face, so bold code then
    /// looks the same as the code around it. Off, the view does not make the
    /// fonts heavier itself. See `withBoldText(_:)`.
    public var followsBoldText = true
    /// Whether the Bold Text setting is on, as `withBoldText(_:)` sets it.
    var isBoldTextOn = false
    /// Whether layout makes the fonts heavier for Bold Text.
    var usesBoldText: Bool { isBoldTextOn && followsBoldText }

    public var bodySize: CGFloat = 17
    public var lineSpacing: CGFloat = 3
    public var blockSpacing: CGFloat = 14
    /// Spacing above a list item that follows other list content.
    public var listItemSpacing: CGFloat = 6
    public var codePadding: CGFloat = 12
    /// Indent added by each list item; the marker sits inside it.
    public var listIndent: CGFloat = 24
    /// Indent added by each block quote; its bar sits at the left of it.
    public var quoteIndent: CGFloat = 14
    /// Space between a table cell's border and its text.
    public var tableCellPadding: CGFloat = 8
    /// The tallest an image is shown; wider ones are scaled to fit the width.
    public var maximumImageHeight: CGFloat = 360

    /// The color of the text. Nil uses the system's label color.
    public var textColor: TranscriptColor?
    /// The color of links and their underlines. A custom tag's color wins over it.
    public var linkColor = TranscriptColor(red: 0, green: 0.478, blue: 1)
    /// Behind code blocks, table headers and image placeholders. Nil uses the
    /// system's secondary fill color. `tableHeaderBackgroundColor` wins over
    /// it for table headers.
    public var codeBackgroundColor: TranscriptColor?
    /// Quote bars, thematic breaks and table lines. Nil uses the system's
    /// tertiary label color. `quoteBarColor` wins over it for quote bars.
    public var accentColor: TranscriptColor?

    /// How the numbers of ordered list items are written.
    public var listNumberFormat: TranscriptListNumberFormat = .asWritten
    /// The weight of the numbers of ordered list items, from -1 to 1 as
    /// `TranscriptFont.weight`. Nil uses the weight of the body text. A named
    /// body font has its own weight: a weight of 0.3 or more uses its bold
    /// face, and a lower weight uses the font as it is.
    public var listNumberWeight: CGFloat?
    /// The color of the numbers of ordered list items. Nil uses the text
    /// color, or `quoteTextColor` in a block quote.
    public var listNumberColor: TranscriptColor?
    /// The bullets of unordered list items: the first for level 1, the
    /// second for level 2, and so on. Levels past the end use the last one.
    /// Empty uses "•", "◦" and "▪".
    public var bullets: [String] = TranscriptStyle.defaultBullets
    /// The colors of the bullets, by level as `bullets`. Empty uses the text
    /// color, or `quoteTextColor` in a block quote.
    public var bulletColors: [TranscriptColor] = []
    /// The fill of a task box that is checked. Nil uses a system-like blue.
    public var taskCheckedColor: TranscriptColor?
    /// The check mark in a task box that is checked. Nil uses white.
    public var taskCheckmarkColor: TranscriptColor?
    /// The outline of a task box that is not checked. Nil uses the text color,
    /// or `quoteTextColor` in a block quote, at 45% opacity.
    public var taskUncheckedColor: TranscriptColor?
    /// The color of the bar at the left of a block quote. Nil uses
    /// `accentColor`.
    public var quoteBarColor: TranscriptColor?
    /// The width of the bar at the left of a block quote. Keep it less than
    /// `quoteIndent`, or the bar covers the text.
    public var quoteBarWidth: CGFloat = 3
    /// The color of the text in block quotes. Nil uses the text color. Links,
    /// code colors and custom tags' colors win over it.
    public var quoteTextColor: TranscriptColor?
    /// The fill behind inline code. Nil draws no fill. A custom tag's
    /// highlight wins over it.
    public var inlineCodeBackgroundColor: TranscriptColor?
    /// The corner radius of the fill behind inline code.
    public var inlineCodeCornerRadius: CGFloat = 4
    /// The fill behind the header row of a table. Nil uses
    /// `codeBackgroundColor`.
    public var tableHeaderBackgroundColor: TranscriptColor?
    /// The weight of the text in the header row of a table, from -1 to 1 as
    /// `TranscriptFont.weight`. Nil uses the bold body font. A named body font
    /// has its own weight: a weight of 0.3 or more uses its bold face, and a
    /// lower weight uses the font as it is. Inline code in the header row uses
    /// its bold face at a weight of 0.3 or more.
    public var tableHeaderWeight: CGFloat?

    public init() {}

    /// The most lines to show, or nil for all of them. When text is left out,
    /// the last line shown ends in "…". The selection shows only on the text
    /// that is shown, but a selection that reaches its end also copies the
    /// text that is left out, and VoiceOver reads all of the text. Tables
    /// are shown whole or not at all.
    public var lineLimit: Int?
    /// Where the lines of paragraphs and headings sit in their column. Lists,
    /// quotes, code and tables stay at the leading edge.
    public var textAlignment: TranscriptTextAlignment = .leading
    /// Whether the lines of code blocks wrap at the width of the text column.
    /// On by default. Off, a line of code breaks only where its text has a
    /// line break, and a code block with a line that is wider than the column
    /// scrolls sideways in `TranscriptTextView`. The block keeps the width of
    /// the column.
    public var codeWraps = true
    /// Where a paragraph that holds only display math puts its formula in the
    /// column. Centered by default. A formula that is wider than the column
    /// starts at the leading edge.
    public var displayMathAlignment: TranscriptTextAlignment = .center
    /// Whether a display formula that is wider than the text column scrolls
    /// sideways in `TranscriptTextView`. Off by default: the formula is then
    /// scaled down to fit. Inline formulas are always scaled down.
    public var displayMathScrolls = false

    struct Insets {
        var leading: CGFloat = 0
        var trailing: CGFloat = 0
        var vertical: CGFloat = 0
    }

    func width(of container: TranscriptBlock.Container) -> CGFloat {
        switch container {
        case .quote: return quoteIndent
        case .listItem: return listIndent
        }
    }

    /// The color of text inside `containers`, outermost first: the quote text
    /// color when one of them is a block quote, or else nil for the text color.
    func textColor<Containers: Collection>(inside containers: Containers) -> TranscriptColor?
        where Containers.Element == TranscriptBlock.Container {
        containers.contains(.quote) ? quoteTextColor : nil
    }

    static let defaultBullets = ["•", "◦", "▪"]

    /// The bullet of a list item at `level`, from 1, and its color.
    func bullet(at level: Int) -> (text: String, color: TranscriptColor?) {
        let shapes = bullets.isEmpty ? Self.defaultBullets : bullets
        let color = bulletColors.isEmpty ? nil : bulletColors[min(max(level, 1), bulletColors.count) - 1]
        return (shapes[min(max(level, 1), shapes.count) - 1], color)
    }

    /// Where the block's own box starts: after the indents of its containers.
    func contentLeading(for containers: [TranscriptBlock.Container]) -> CGFloat {
        containers.reduce(0) { $0 + width(of: $1) }
    }

    func insets(for block: TranscriptBlock) -> Insets {
        let leading = contentLeading(for: block.containers)
        switch block.kind {
        case .code:
            return Insets(leading: leading + codePadding, trailing: codePadding, vertical: codePadding)
        case .paragraph, .heading, .rule, .table:
            return Insets(leading: leading)
        }
    }

    /// Creating fonts is slow enough to show up in profiles, and a transcript
    /// only ever uses a handful, so they are cached.
    private final class FontCache: @unchecked Sendable {
        struct Key: Hashable {
            var role: Int
            var size: CGFloat
            var traits: Int
            var weight: CGFloat?
            var font: TranscriptFont?
            var code: TranscriptFont?
            var boldText: Bool
            var followsBoldText: Bool
        }

        private let lock = NSLock()
        private var fonts: [Key: CTFont] = [:]

        func font(for key: Key, make: () -> CTFont) -> CTFont {
            lock.lock()
            defer { lock.unlock() }
            if let font = fonts[key] { return font }
            let font = make()
            fonts[key] = font
            return font
        }
    }

    private static let fontCache = FontCache()
    /// The traits that change the font; the others are drawn.
    private static let fontTraits: InlineSpan.Traits = [.bold, .italic, .code]

    /// - Parameter weight: for body text, a weight as `TranscriptFont.weight`
    ///   instead of the body font's own.
    func font(for kind: TranscriptBlock.Kind, traits: InlineSpan.Traits = [], weight: CGFloat? = nil) -> CTFont {
        let traits = traits.intersection(Self.fontTraits)
        var weight = weight
        let role: Int
        switch kind {
        case .paragraph, .rule, .table: role = 0
        case .heading(let level):
            role = min(max(level, 1), 6)
            weight = nil
        case .code:
            role = 7
            weight = nil
        }
        let key = FontCache.Key(role: role, size: bodySize, traits: traits.rawValue, weight: weight, font: customFont(for: kind),
                                code: traits.contains(.code) ? codeFont : nil, boldText: isBoldTextOn,
                                followsBoldText: followsBoldText)
        return Self.fontCache.font(for: key) { makeFont(for: kind, traits: traits, weight: weight) }
    }

    /// The font that a formula's LaTeX is shown in until it is drawn: the
    /// code font at `size`.
    func mathFallbackFont(size: CGFloat) -> CTFont {
        let key = FontCache.Key(role: 8, size: size, traits: 0, weight: nil, font: nil, code: codeFont, boldText: isBoldTextOn,
                                followsBoldText: followsBoldText)
        return Self.fontCache.font(for: key) {
            adjustedForBoldText(codeFont?.makeFont(size: size) ?? CTFontCreateUIFontForLanguage(.userFixedPitch, size, nil)!,
                                source: codeFont, defaultWeight: nil, traits: [])
        }
    }

    /// The font the app set for this kind of text, if any.
    func customFont(for kind: TranscriptBlock.Kind) -> TranscriptFont? {
        switch kind {
        case .paragraph, .rule, .table: return bodyFont
        case .heading(let level):
            guard !headingFonts.isEmpty else { return nil }
            return headingFonts[min(max(level, 1), headingFonts.count) - 1]
        case .code: return codeFont
        }
    }

    /// The line height the app set for this kind of text, if any.
    func lineHeight(for kind: TranscriptBlock.Kind) -> CGFloat? {
        customFont(for: kind)?.lineHeight
    }

    /// The size of body text: the body font's, or `bodySize`.
    var effectiveBodySize: CGFloat { bodyFont?.size ?? bodySize }

    private func makeFont(for kind: TranscriptBlock.Kind, traits: InlineSpan.Traits, weight: CGFloat?) -> CTFont {
        var font: CTFont
        var traits = traits
        var source = customFont(for: kind)
        if let weight {
            if let custom = customFont(for: kind), custom.name != nil {
                font = custom.makeFont()
                if weight >= 0.3 { traits.insert(.bold) }
            } else {
                var custom = customFont(for: kind) ?? TranscriptFont(size: bodySize)
                custom.weight = weight
                font = custom.makeFont()
                source = custom
                // The code font below replaces this font and its weight.
                if weight >= 0.3, traits.contains(.code) { traits.insert(.bold) }
            }
        } else if let custom = customFont(for: kind) {
            font = custom.makeFont()
        } else {
            switch kind {
            case .paragraph, .rule, .table:
                font = CTFontCreateUIFontForLanguage(.system, bodySize, nil)!
            case .heading(let level):
                let scale: CGFloat = level <= 1 ? 1.5 : (level == 2 ? 1.3 : 1.15)
                font = CTFontCreateUIFontForLanguage(.emphasizedSystem, bodySize * scale, nil)!
            case .code:
                font = CTFontCreateUIFontForLanguage(.userFixedPitch, bodySize * 0.88, nil)!
            }
        }
        if traits.contains(.code) {
            let size = CTFontGetSize(font) * 0.9
            font = codeFont?.makeFont(size: size) ?? CTFontCreateUIFontForLanguage(.userFixedPitch, size, nil)!
        }
        var symbolic: CTFontSymbolicTraits = []
        if traits.contains(.bold) { symbolic.insert(.traitBold) }
        if traits.contains(.italic) { symbolic.insert(.traitItalic) }
        if !symbolic.isEmpty, let styled = CTFontCreateCopyWithSymbolicTraits(font, 0, nil, symbolic, symbolic) {
            font = styled
        }
        if traits.contains(.code) { source = codeFont }
        let defaultWeight: CGFloat? = switch kind {
        case _ where traits.contains(.code): nil
        case .paragraph, .rule, .table: 0
        case .heading: 0.4
        case .code: nil
        }
        return adjustedForBoldText(font, source: source, defaultWeight: defaultWeight, traits: traits)
    }

    /// A copy for when the Bold Text setting is `isOn`. With
    /// `followsBoldText`, its system fonts are heavier when `isOn` is true.
    /// `TranscriptTextView` applies it from the trait collection's
    /// `legibilityWeight`. With a `DocumentLayout` of your own, lay out with
    /// the copy, and lay out again when the setting changes.
    public func withBoldText(_ isOn: Bool) -> TranscriptStyle {
        var copy = self
        copy.isBoldTextOn = isOn
        return copy
    }

    /// `font` as Bold Text sets it, when `usesBoldText` is on.
    ///
    /// - Parameters:
    ///   - source: the app's font that `font` was made from, or nil for a
    ///     default one.
    ///   - defaultWeight: the weight of the default system font, or nil if
    ///     the default is the fixed-pitch font.
    func adjustedForBoldText(_ font: CTFont, source: TranscriptFont?, defaultWeight: CGFloat?,
                             traits: InlineSpan.Traits) -> CTFont {
        guard usesBoldText else { return font }
        if let source, source.name != nil { return font }
        guard let declared = source?.weight ?? defaultWeight else {
            if CTFontGetSymbolicTraits(font).contains(.traitBold) { return font }
            return CTFontCreateCopyWithSymbolicTraits(font, 0, nil, .traitBold, .traitBold) ?? font
        }
        // From the weight asked for, not the weight measured: the system
        // may already give a heavier font for Bold Text, and that font is
        // then kept as it is.
        let target = TranscriptFont.boldTextWeight(traits.contains(.bold) ? max(declared, 0.4) : declared)
        guard Self.weight(of: font) < target - 0.01 else { return font }
        var heavier = TranscriptFont(size: CTFontGetSize(font), weight: target, monospaced: source?.monospaced ?? false).makeFont()
        if traits.contains(.italic), let styled = CTFontCreateCopyWithSymbolicTraits(heavier, 0, nil, .traitItalic, .traitItalic) {
            heavier = styled
        }
        return heavier
    }

    static func weight(of font: CTFont) -> CGFloat {
        let traits = CTFontCopyTraits(font) as NSDictionary
        return (traits[kCTFontWeightTrait] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
    }

    static let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
    private static let colorFromContextKey = NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String)
    private static let runDelegateKey = NSAttributedString.Key(kCTRunDelegateAttributeName as String)
    /// Core Text has no strikethrough, and its underline does not survive
    /// run-by-run drawing, so both are marked and drawn by `DocumentLayout`.
    static let strikethroughKey = NSAttributedString.Key("TranscriptKit.strikethrough")
    static let underlineKey = NSAttributedString.Key("TranscriptKit.underline")
    /// Marks the U+FFFC that stands for an image; the value is an `ImageAttachment`.
    static let imageKey = NSAttributedString.Key("TranscriptKit.image")
    /// A custom tag's text color and highlight, `TranscriptColor`s. They are
    /// resolved for light or dark when drawn, by `DocumentLayout`.
    static let foregroundKey = NSAttributedString.Key("TranscriptKit.foreground")
    static let backgroundKey = NSAttributedString.Key("TranscriptKit.background")
    /// The fill behind inline code, a `TranscriptColor`, drawn like a highlight.
    static let inlineCodeBackgroundKey = NSAttributedString.Key("TranscriptKit.inlineCodeBackground")
    private static let kernKey = NSAttributedString.Key(kCTKernAttributeName as String)

    func attributes(for kind: TranscriptBlock.Kind, weight: CGFloat? = nil) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            Self.fontKey: font(for: kind, weight: weight),
            // Text takes the context's fill color, so the view controls light/dark.
            Self.colorFromContextKey: true,
        ]
        if let spacing = customFont(for: kind)?.letterSpacing, spacing != 0 { attributes[Self.kernKey] = spacing }
        return attributes
    }

    /// The styled text of `block` from UTF-16 offset `start` to its end.
    func attributedString(for block: TranscriptBlock, from start: Int = 0, images: ImageSizing? = nil,
                          definitions: [String: String] = [:], kerns: [Int: CGFloat] = [:]) -> NSAttributedString {
        attributedString(for: block, range: start..<block.utf16Count, images: images, definitions: definitions, kerns: kerns)
    }

    /// The styled text of `range` of `block`, with `extraTraits` added to all
    /// of it, and in `weight` (as `TranscriptFont.weight`) if it is body text.
    /// A reference link is styled as a link once `definitions` has its label.
    /// `kerns` is extra advance after characters, by block offset: room for
    /// custom tags' padding (see `DecoratedTags`).
    func attributedString(for block: TranscriptBlock, range: Range<Int>, extraTraits: InlineSpan.Traits = [], weight: CGFloat? = nil,
                          images: ImageSizing? = nil, definitions: [String: String] = [:],
                          kerns: [Int: CGFloat] = [:]) -> NSAttributedString {
        let start = range.lowerBound
        let text = range == 0..<block.utf16Count ? block.text : (block.text as NSString).substring(with: NSRange(location: start, length: range.count))
        var base = attributes(for: block.kind, weight: weight)
        if !extraTraits.isEmpty { base[Self.fontKey] = font(for: block.kind, traits: extraTraits, weight: weight) }
        if let color = textColor(inside: block.containers) { base[Self.foregroundKey] = color }
        let result = NSMutableAttributedString(string: text, attributes: base)
        let length = result.length
        if case .code(let language) = block.kind, let store = images?.store {
            // The app's highlighter's colors, drawn like a tag's color.
            for mark in store.highlights(for: block.id, text: block.text, language: language) {
                let lower = min(max(mark.range.lowerBound - start, 0), length)
                let upper = min(max(mark.range.upperBound - start, 0), length)
                guard lower < upper else { continue }
                let range = NSRange(location: lower, length: upper - lower)
                result.addAttribute(Self.foregroundKey, value: mark.color, range: range)
                let traits = mark.traits.intersection([.bold, .italic])
                if !traits.isEmpty { result.addAttribute(Self.fontKey, value: font(for: block.kind, traits: traits), range: range) }
            }
        }
        // Spans shifted into the substring's coordinates, dropping any outside it.
        let spans = block.spans.compactMap { span -> InlineSpan? in
            let lower = min(max(span.range.lowerBound - start, 0), length)
            let upper = min(max(span.range.upperBound - start, 0), length)
            guard lower < upper else { return nil }
            var shifted = span
            shifted.range = lower..<upper
            return shifted
        }
        guard !spans.isEmpty else { return result }

        // Spans may overlap (bold inside a link), so style each stretch between
        // span boundaries with the union of the spans covering it.
        var cuts: Set<Int> = [0, length]
        for span in spans {
            cuts.insert(span.range.lowerBound)
            cuts.insert(span.range.upperBound)
        }
        let sorted = cuts.sorted()
        var mathStarts: [Int]?
        for (lower, upper) in zip(sorted, sorted.dropFirst()) {
            var traits = extraTraits
            var isLink = false
            var image: TranscriptImage?
            var math: (math: TranscriptMath, start: Int)?
            // Spans are sorted with outer ones first, so an inner tag's colors win.
            var foreground: TranscriptColor?
            var background: TranscriptColor?
            for span in spans where span.range.lowerBound <= lower && span.range.upperBound >= upper {
                traits.formUnion(span.traits)
                if span.link != nil || span.reference.map({ definitions[$0] != nil }) == true { isLink = true }
                if let spanImage = span.image { image = spanImage }
                if let spanMath = span.math { math = (spanMath, span.range.lowerBound + start) }
                if let decoration = span.customTag?.decoration {
                    if let color = decoration.foreground { foreground = color }
                    if let color = decoration.background { background = color }
                }
            }
            let range = NSRange(location: lower, length: upper - lower)
            if !traits.intersection(Self.fontTraits).isEmpty {
                result.addAttribute(Self.fontKey, value: font(for: block.kind, traits: traits, weight: weight), range: range)
            }
            if traits.contains(.strikethrough) { result.addAttribute(Self.strikethroughKey, value: true, range: range) }
            if traits.contains(.underline) { result.addAttribute(Self.underlineKey, value: true, range: range) }
            if let foreground {
                // Drawn in the context's fill color, which `DocumentLayout` sets to it.
                result.addAttribute(Self.foregroundKey, value: foreground, range: range)
            } else if isLink {
                // Resolved for light or dark when drawn, like a tag's color.
                result.addAttribute(Self.foregroundKey, value: linkColor, range: range)
            }
            if let background {
                result.addAttribute(Self.backgroundKey, value: background, range: range)
            } else if traits.contains(.code), let fill = inlineCodeBackgroundColor {
                result.addAttribute(Self.inlineCodeBackgroundKey, value: fill, range: range)
            }
            if image != nil || math != nil, range.length == 1 {
                let font = result.attribute(Self.fontKey, at: lower, effectiveRange: nil).map { $0 as! CTFont } ?? self.font(for: block.kind)
                let attachment = math.map { math -> ImageAttachment in
                    if mathStarts == nil { mathStarts = Self.mathStarts(in: block) }
                    let slot = Self.mathSlot(in: block, at: math.start, starts: mathStarts!)
                    return ImageAttachment(math: math.math, slot: slot, sizing: images, font: font, style: self)
                } ?? ImageAttachment(image: image!, sizing: images, font: font, style: self)
                result.addAttribute(Self.imageKey, value: attachment, range: range)
                result.addAttribute(Self.runDelegateKey, value: attachment.makeRunDelegate(), range: range)
            }
        }
        for (offset, kern) in kerns where offset >= start && offset < start + length {
            // On the whole character, so a glyph made of several units keeps it.
            let character = (result.string as NSString).rangeOfComposedCharacterSequence(at: offset - start)
            result.addAttribute(Self.kernKey, value: kern + (customFont(for: block.kind)?.letterSpacing ?? 0), range: character)
        }
        return result
    }
}

extension TranscriptStyle {
    /// The slot of the formula that starts at UTF-16 offset `start` of
    /// `block`: it is the same whichever part of the block is laid out.
    static func mathSlot(in block: TranscriptBlock, at start: Int) -> TranscriptImageStore.MathSlot {
        mathSlot(in: block, at: start, starts: mathStarts(in: block))
    }

    /// The same, with the block's `mathStarts`.
    static func mathSlot(in block: TranscriptBlock, at start: Int, starts: [Int]) -> TranscriptImageStore.MathSlot {
        var low = 0
        var high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] < start { low = middle + 1 } else { high = middle }
        }
        return TranscriptImageStore.MathSlot(block: block.id, index: low)
    }

    /// Where the block's formulas start, in order.
    static func mathStarts(in block: TranscriptBlock) -> [Int] {
        block.spans.compactMap { $0.math != nil ? $0.range.lowerBound : nil }.sorted()
    }
}

/// What layout needs to know to size images: the loaded ones, and the width
/// they must fit in.
struct ImageSizing {
    var store: TranscriptImageStore?
    var maximumWidth: CGFloat
}

/// An image in laid-out text: the loaded picture, or a placeholder showing
/// the alt text when there is none. A formula that is being drawn has
/// neither: it is empty space.
final class ImageAttachment: @unchecked Sendable {
    let image: TranscriptImage
    let picture: CGImage?
    /// Placeholder text, when there is no picture.
    let label: CTLine?
    let size: CGSize
    /// Above the baseline; the rest of `size.height` is below it.
    let ascent: CGFloat
    /// For a formula: it, and its picture is a mask drawn in the text color.
    let math: TranscriptMath?
    var isMask: Bool { math != nil && picture != nil }

    /// A formula, drawn by the store's math renderer. Until it is, it is empty
    /// space of about its size. Without a renderer, or if the renderer cannot
    /// draw it, it is its LaTeX as written.
    init(math: TranscriptMath, slot: TranscriptImageStore.MathSlot, sizing: ImageSizing?, font: CTFont, style: TranscriptStyle) {
        self.image = TranscriptImage(source: "", alt: math.tex)
        self.math = math
        let maximumWidth = max(sizing?.maximumWidth ?? 320, 20)
        let formula = sizing?.store?.formula(for: math, fontSize: CTFontGetSize(font), in: slot) ?? .asWritten
        if case .drawn(let formula) = formula {
            let natural = CGSize(width: max(formula.size.width, 1), height: max(formula.size.height, 1))
            let scale = min(1, maximumWidth / natural.width)
            self.picture = formula.image
            self.label = nil
            self.size = CGSize(width: ceil(natural.width * scale), height: ceil(natural.height * scale))
            self.ascent = size.height - formula.baseline * scale
        } else if case .pending = formula {
            self.picture = nil
            self.label = nil
            (self.size, self.ascent) = Self.reservedSpace(for: math, font: font, maximumWidth: maximumWidth)
        } else {
            let size = CTFontGetSize(font) * 0.85
            let code = style.mathFallbackFont(size: size)
            let attributes: [NSAttributedString.Key: Any] = [
                TranscriptStyle.fontKey: code,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ]
            var line = CTLineCreateWithAttributedString(NSAttributedString(string: math.source, attributes: attributes))
            let padding: CGFloat = 6
            let available = maximumWidth - padding * 2
            if CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) > available {
                let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
                line = CTLineCreateTruncatedLine(line, Double(available), .end, ellipsis) ?? line
            }
            self.picture = nil
            self.label = line
            let width = ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))) + padding * 2
            self.size = CGSize(width: min(width, maximumWidth), height: ceil(CTFontGetAscent(font) + CTFontGetDescent(font)) + 4)
            self.ascent = ceil(CTFontGetAscent(font)) + 2
        }
    }

    /// Room for a formula that is not drawn yet, so that the text around it
    /// moves less when it is: about as wide as its symbols, and one line
    /// tall for inline math. Display math gets a line for each of its rows,
    /// and two when it has a fraction, a sum or an integral.
    static func reservedSpace(for math: TranscriptMath, font: CTFont, maximumWidth: CGFloat) -> (size: CGSize, ascent: CGFloat) {
        let fontSize = CTFontGetSize(font)
        let ascent = ceil(CTFontGetAscent(font))
        let lineHeight = ceil(CTFontGetAscent(font) + CTFontGetDescent(font))
        let shape = LatexShape(math.tex)
        let rows = math.isDisplay ? shape.rows : 1
        let symbolsInARow = (shape.symbols + rows - 1) / rows
        let width = min(max(CGFloat(symbolsInARow) * fontSize * 0.55, fontSize).rounded(), maximumWidth)
        guard math.isDisplay else { return (CGSize(width: width, height: lineHeight), ascent) }
        let height = lineHeight * CGFloat(rows) * (shape.isTall ? 2 : 1)
        return (CGSize(width: width, height: height), height - (lineHeight - ascent))
    }

    init(image: TranscriptImage, sizing: ImageSizing?, font: CTFont, style: TranscriptStyle) {
        self.image = image
        self.math = nil
        let maximumWidth = max(sizing?.maximumWidth ?? 320, 20)
        if let picture = sizing?.store?.picture(for: image) {
            let natural = CGSize(width: max(CGFloat(picture.width), 1), height: max(CGFloat(picture.height), 1))
            let scale = min(1, maximumWidth / natural.width, style.maximumImageHeight / natural.height)
            self.picture = picture
            self.label = nil
            self.size = CGSize(width: floor(natural.width * scale), height: floor(natural.height * scale))
            // Sits on the baseline, like a tall character.
            self.ascent = size.height
        } else {
            let text = image.alt.isEmpty ? "Image" : image.alt
            let small = CTFontCreateCopyWithAttributes(font, CTFontGetSize(font) * 0.85, nil, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                TranscriptStyle.fontKey: small,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ]
            var line = CTLineCreateWithAttributedString(NSAttributedString(string: "▨ " + text, attributes: attributes))
            let padding: CGFloat = 6
            let available = maximumWidth - padding * 2
            if CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) > available {
                let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
                line = CTLineCreateTruncatedLine(line, Double(available), .end, ellipsis) ?? line
            }
            self.picture = nil
            self.label = line
            let width = ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))) + padding * 2
            self.size = CGSize(width: min(width, maximumWidth), height: ceil(CTFontGetAscent(font) + CTFontGetDescent(font)) + 4)
            self.ascent = ceil(CTFontGetAscent(font)) + 2
        }
    }

    func makeRunDelegate() -> CTRunDelegate {
        var callbacks = CTRunDelegateCallbacks(
            version: kCTRunDelegateVersion1,
            dealloc: { Unmanaged<ImageAttachment>.fromOpaque($0).release() },
            getAscent: { Unmanaged<ImageAttachment>.fromOpaque($0).takeUnretainedValue().ascent },
            getDescent: {
                let attachment = Unmanaged<ImageAttachment>.fromOpaque($0).takeUnretainedValue()
                return attachment.size.height - attachment.ascent
            },
            getWidth: { Unmanaged<ImageAttachment>.fromOpaque($0).takeUnretainedValue().size.width }
        )
        return CTRunDelegateCreate(&callbacks, Unmanaged.passRetained(self).toOpaque())!
    }
}

/// A rough count of what a formula draws, read from its LaTeX.
struct LatexShape: Equatable {
    /// Letters, digits, operators and symbol commands such as `\alpha`.
    var symbols = 0
    /// Rows, which `\\` separates.
    var rows = 1
    /// It has a fraction, a sum, an integral or a product, which are about
    /// twice as tall as a line.
    var isTall = false

    private static let layoutCommands: Set<Substring> = [
        "frac", "dfrac", "tfrac", "left", "right", "mathrm", "mathbf", "mathit", "mathsf", "text", "textrm",
        "operatorname", "displaystyle", "textstyle", "limits",
    ]
    private static let tallCommands: Set<Substring> = ["frac", "dfrac", "sum", "int", "iint", "oint", "prod", "coprod", "binom"]

    init(_ tex: String) {
        let units = Substring(tex)
        var index = units.startIndex
        while index < units.endIndex {
            let character = units[index]
            index = units.index(after: index)
            guard character == "\\" else {
                if !(character.isWhitespace || "{}^_&~".contains(character)) { symbols += 1 }
                continue
            }
            let name = units[index...].prefix { $0.isLetter }
            guard !name.isEmpty else {
                // An escaped character, `\\` between rows, or a space such as `\,`.
                guard index < units.endIndex else { break }
                let escaped = units[index]
                if escaped == "\\" { rows += 1 } else if "{}|%$#".contains(escaped) { symbols += 1 }
                index = units.index(after: index)
                continue
            }
            index = name.endIndex
            if Self.tallCommands.contains(name) { isTall = true }
            if name == "begin" || name == "end" {
                // The environment's name is not drawn.
                if index < units.endIndex, units[index] == "{", let close = units[index...].firstIndex(of: "}") {
                    index = units.index(after: close)
                }
            } else if !Self.layoutCommands.contains(name) {
                symbols += 1
            }
        }
    }
}
