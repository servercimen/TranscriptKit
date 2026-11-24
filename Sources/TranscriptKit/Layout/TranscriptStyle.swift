import CoreGraphics
import CoreText
import Foundation

/// Where lines sit in their column; see `TranscriptStyle.textAlignment`.
public enum TranscriptTextAlignment: Hashable, Sendable {
    case leading
    case center
    case trailing
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
    /// system's secondary fill color.
    public var codeBackgroundColor: TranscriptColor?
    /// Quote bars, thematic breaks and table lines. Nil uses the system's
    /// tertiary label color.
    public var accentColor: TranscriptColor?

    public init() {}

    /// The most lines to show, or nil for all of them. When text is left out,
    /// the last line shown ends in "…". Selection and copying cover only the
    /// text that is shown. Tables are shown whole or not at all.
    public var lineLimit: Int?
    /// Where the lines of paragraphs and headings sit in their column. Lists,
    /// quotes, code and tables stay at the leading edge.
    public var textAlignment: TranscriptTextAlignment = .leading

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

    func font(for kind: TranscriptBlock.Kind, traits: InlineSpan.Traits = []) -> CTFont {
        let traits = traits.intersection(Self.fontTraits)
        let role: Int
        switch kind {
        case .paragraph, .rule, .table: role = 0
        case .heading(let level): role = min(max(level, 1), 6)
        case .code: role = 7
        }
        let key = FontCache.Key(role: role, size: bodySize, traits: traits.rawValue, font: customFont(for: kind),
                                code: traits.contains(.code) ? codeFont : nil, boldText: isBoldTextOn,
                                followsBoldText: followsBoldText)
        return Self.fontCache.font(for: key) { makeFont(for: kind, traits: traits) }
    }

    /// The font that a formula's LaTeX is shown in until it is drawn: the
    /// code font at `size`.
    func mathFallbackFont(size: CGFloat) -> CTFont {
        let key = FontCache.Key(role: 8, size: size, traits: 0, font: nil, code: codeFont, boldText: isBoldTextOn,
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

    private func makeFont(for kind: TranscriptBlock.Kind, traits: InlineSpan.Traits) -> CTFont {
        var font: CTFont
        if let custom = customFont(for: kind) {
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
        let source = traits.contains(.code) ? codeFont : customFont(for: kind)
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
    private static let kernKey = NSAttributedString.Key(kCTKernAttributeName as String)

    func attributes(for kind: TranscriptBlock.Kind) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            Self.fontKey: font(for: kind),
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

    /// The styled text of `range` of `block`, with `extraTraits` added to all of it.
    /// A reference link is styled as a link once `definitions` has its label.
    /// `kerns` is extra advance after characters, by block offset: room for
    /// custom tags' padding (see `DecoratedTags`).
    func attributedString(for block: TranscriptBlock, range: Range<Int>, extraTraits: InlineSpan.Traits = [],
                          images: ImageSizing? = nil, definitions: [String: String] = [:],
                          kerns: [Int: CGFloat] = [:]) -> NSAttributedString {
        let start = range.lowerBound
        let text = range == 0..<block.utf16Count ? block.text : (block.text as NSString).substring(with: NSRange(location: start, length: range.count))
        var base = attributes(for: block.kind)
        if !extraTraits.isEmpty { base[Self.fontKey] = font(for: block.kind, traits: extraTraits) }
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
        for (lower, upper) in zip(sorted, sorted.dropFirst()) {
            var traits = extraTraits
            var isLink = false
            var image: TranscriptImage?
            var math: TranscriptMath?
            // Spans are sorted with outer ones first, so an inner tag's colors win.
            var foreground: TranscriptColor?
            var background: TranscriptColor?
            for span in spans where span.range.lowerBound <= lower && span.range.upperBound >= upper {
                traits.formUnion(span.traits)
                if span.link != nil || span.reference.map({ definitions[$0] != nil }) == true { isLink = true }
                if let spanImage = span.image { image = spanImage }
                if let spanMath = span.math { math = spanMath }
                if let decoration = span.customTag?.decoration {
                    if let color = decoration.foreground { foreground = color }
                    if let color = decoration.background { background = color }
                }
            }
            let range = NSRange(location: lower, length: upper - lower)
            if !traits.intersection(Self.fontTraits).isEmpty {
                result.addAttribute(Self.fontKey, value: font(for: block.kind, traits: traits), range: range)
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
            if let background { result.addAttribute(Self.backgroundKey, value: background, range: range) }
            if image != nil || math != nil, range.length == 1 {
                let font = result.attribute(Self.fontKey, at: lower, effectiveRange: nil).map { $0 as! CTFont } ?? self.font(for: block.kind)
                let attachment = math.map { ImageAttachment(math: $0, sizing: images, font: font, style: self) }
                    ?? ImageAttachment(image: image!, sizing: images, font: font, style: self)
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

/// What layout needs to know to size images: the loaded ones, and the width
/// they must fit in.
struct ImageSizing {
    var store: TranscriptImageStore?
    var maximumWidth: CGFloat
}

/// An image in laid-out text: the loaded picture, or a placeholder showing
/// the alt text when there is none.
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

    /// A formula, drawn by the store's math renderer, or its LaTeX as written
    /// until it is (or if it is not).
    init(math: TranscriptMath, sizing: ImageSizing?, font: CTFont, style: TranscriptStyle) {
        self.image = TranscriptImage(source: "", alt: math.tex)
        self.math = math
        let maximumWidth = max(sizing?.maximumWidth ?? 320, 20)
        if let formula = sizing?.store?.formula(for: math, fontSize: CTFontGetSize(font)) {
            let natural = CGSize(width: max(formula.size.width, 1), height: max(formula.size.height, 1))
            let scale = min(1, maximumWidth / natural.width)
            self.picture = formula.image
            self.label = nil
            self.size = CGSize(width: ceil(natural.width * scale), height: ceil(natural.height * scale))
            self.ascent = size.height - formula.baseline * scale
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
