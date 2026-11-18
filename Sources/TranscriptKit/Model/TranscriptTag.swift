import CoreGraphics
import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// A tag that Markdown may use besides the built-in HTML ones, and how the
/// text inside it looks.
///
/// ```swift
/// let tags = [
///     TranscriptTag("mark", TranscriptDecoration(background: TranscriptColor(UIColor.systemYellow.withAlphaComponent(0.4)))),
///     TranscriptTag("mention") { attributes in
///         TranscriptDecoration(traits: .bold, foreground: TranscriptColor(UIColor.systemIndigo),
///                              link: attributes["id"].map { "myapp://people/\($0)" })
///     },
/// ]
/// let stream = TranscriptStream(tags: tags)
/// stream.append(#"Ask <mention id="42">@ana</mention> about the <mark>Q3 numbers</mark>."#)
/// ```
///
/// Tags are given to the parser (`TranscriptStream`, `MarkdownStreamParser`),
/// which has to know them to tell a tag from text such as `Array<Int>`: a tag
/// that isn't defined shows as written. The decoration is worked out when the
/// tag is parsed and kept with the text (`InlineSpan.customTag`), so a
/// document shows its tags the same in every view; to change how they look,
/// parse the text again with other definitions.
///
/// - A name starts with a letter and has only letters, digits and `-`. Tags
///   match whatever their case.
/// - Attributes are written `name="value"`, `name='value'` or `name=value`,
///   and are given to the decoration as written (entities are not decoded).
/// - A tag left open decorates the rest of its paragraph, as in a browser;
///   a closing tag with nothing open is dropped.
/// - A tag longer than 256 characters, attributes included, shows as written.
/// - A tag with a built-in name (`b`, `kbd`, ...) replaces the built-in one;
///   `br` can't be replaced.
/// - While text streams, a tag is hidden until its `>` arrives.
public struct TranscriptTag: Sendable {
    /// Lowercase.
    public let name: String
    private let decorate: @Sendable ([String: String]) -> TranscriptDecoration

    /// A tag that always looks the same.
    public init(_ name: String, _ decoration: TranscriptDecoration) {
        self.init(name) { _ in decoration }
    }

    /// A tag whose look depends on its attributes.
    ///
    /// - Parameter decoration: called on the parsing queue, possibly more than
    ///   once for one tag while text streams. Keep it quick and give the same
    ///   result for the same attributes.
    public init(_ name: String, decoration: @escaping @Sendable (_ attributes: [String: String]) -> TranscriptDecoration) {
        let lowered = name.lowercased()
        precondition(Self.isValidName(lowered),
                     "TranscriptTag: \"\(name)\" is not a valid tag name: use a letter, then letters, digits or \"-\"")
        precondition(lowered != "br", "TranscriptTag: <br> is a line break and can't be redefined")
        self.name = lowered
        self.decorate = decoration
    }

    func decoration(for attributes: [String: String]) -> TranscriptDecoration {
        decorate(attributes)
    }

    static func isValidName(_ name: String) -> Bool {
        let units = Array(name.utf16)
        guard let first = units.first, (0x61...0x7A).contains(first) else { return false }
        return units.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2D }
    }

    /// By name, the later of two with the same name winning.
    static func byName(_ tags: [TranscriptTag]) -> [String: TranscriptTag] {
        Dictionary(tags.map { ($0.name, $0) }, uniquingKeysWith: { _, later in later })
    }
}

/// How the text inside a custom tag looks, and whether it is a link.
public struct TranscriptDecoration: Equatable, Sendable {
    /// Added to the text's own: bold, italic, `.code` (monospaced), underline,
    /// strikethrough.
    public var traits: InlineSpan.Traits
    /// The text's color, which also colors its underline and strikethrough.
    /// It wins over a link's color.
    public var foreground: TranscriptColor?
    /// A highlight behind the text, with rounded corners. It is drawn in the
    /// text's line, so it adds no space around the text.
    public var background: TranscriptColor?
    /// Makes the text a link: tapping it opens this through the view's
    /// `openLink` (`openURL` in SwiftUI), like a Markdown link.
    public var link: String?
    /// Space kept on each side of the text, where the tag starts and where
    /// it ends, for instance to keep a pill's outline off the glyphs. It is
    /// laid out as extra spacing between characters, so the text itself is
    /// unchanged.
    public var padding: CGFloat
    /// Shapes drawn behind or over the text: `.pill`, `.underline`, or the
    /// app's own `.custom` ones.
    public var shapes: [Shape]
    /// Played when the tag finishes arriving in streamed text: see
    /// `TranscriptAnimationRecipe`. Until then the tag's text shows without
    /// its shapes.
    public var animation: Animation?

    public init(traits: InlineSpan.Traits = [], foreground: TranscriptColor? = nil, background: TranscriptColor? = nil,
                link: String? = nil, padding: CGFloat = 0, shapes: [Shape] = [], animation: Animation? = nil) {
        self.traits = traits
        self.foreground = foreground
        self.background = background
        self.link = link
        self.padding = max(padding, 0)
        self.shapes = shapes
        self.animation = animation
    }

    /// Whether layout has to do anything for it beyond styling the text.
    var shapesText: Bool { padding > 0 || !shapes.isEmpty || animation != nil }
}

/// A color for decorations, with a value for light and one for dark
/// appearance. Text is drawn off the main thread too, where dynamic UIKit
/// colors can't be resolved, so both values are kept.
public struct TranscriptColor: Hashable, Sendable {
    struct Components: Hashable, Sendable {
        var red: CGFloat
        var green: CGFloat
        var blue: CGFloat
        var alpha: CGFloat
    }

    var light: Components
    var dark: Components

    /// Extended sRGB components, the same in light and dark appearance.
    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
        light = Components(red: red, green: green, blue: blue, alpha: alpha)
        dark = light
    }

    public init(light: TranscriptColor, dark: TranscriptColor) {
        self.light = light.light
        self.dark = dark.dark
    }

    /// The same color in light and dark appearance. Nil if it can't be
    /// converted to sRGB (a pattern, say).
    public init?(_ color: CGColor) {
        guard let components = Self.components(of: color) else { return nil }
        light = components
        dark = components
    }

    #if canImport(UIKit) && !os(watchOS)
    /// A UIKit color, resolved for light and for dark appearance: dynamic
    /// colors such as `.systemBlue` keep both of their values.
    public init(_ color: UIColor) {
        func resolved(_ style: UIUserInterfaceStyle) -> Components {
            let cgColor = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style)).cgColor
            return Self.components(of: cgColor) ?? Components(red: 0, green: 0, blue: 0, alpha: 1)
        }
        light = resolved(.light)
        dark = resolved(.dark)
    }
    #endif

    func cgColor(dark isDark: Bool) -> CGColor {
        let value = isDark ? dark : light
        return CGColor(colorSpace: Self.space, components: [value.red, value.green, value.blue, value.alpha])
            ?? CGColor(red: value.red, green: value.green, blue: value.blue, alpha: value.alpha)
    }

    private static let space = CGColorSpace(name: CGColorSpace.extendedSRGB)!

    private static func components(of color: CGColor) -> Components? {
        guard let converted = color.converted(to: space, intent: .defaultIntent, options: nil),
              let values = converted.components, values.count >= 4 else { return nil }
        return Components(red: values[0], green: values[1], blue: values[2], alpha: values[3])
    }
}

extension InlineSpan {
    /// Text inside a custom tag: the tag's name and attributes as written,
    /// and the decoration they gave it.
    ///
    /// A class, so that a span stays small: most spans have none.
    public final class CustomTag: Equatable, Sendable {
        public let name: String
        public let attributes: [String: String]
        public let decoration: TranscriptDecoration
        /// Set, for a tag with an animation, while its closing tag has not
        /// arrived and more text may still come: its animation plays once
        /// this is no longer so. Always false for other tags.
        let isOpen: Bool
        /// `decoration.shapesText`, and whether it has an animation, worked
        /// out once: layout asks on every update.
        let shapesText: Bool
        let isAnimated: Bool

        init(name: String, attributes: [String: String], decoration: TranscriptDecoration, isOpen: Bool = false) {
            self.name = name
            self.attributes = attributes
            self.decoration = decoration
            self.isOpen = isOpen && decoration.animation != nil
            self.shapesText = decoration.shapesText
            self.isAnimated = decoration.animation != nil
        }

        /// The same tag, still waiting for its closing tag. Itself for a tag
        /// without an animation, which looks the same either way.
        var waitingToClose: CustomTag {
            decoration.animation == nil || isOpen ? self
                : CustomTag(name: name, attributes: attributes, decoration: decoration, isOpen: true)
        }

        public static func == (a: CustomTag, b: CustomTag) -> Bool {
            a === b || (a.name == b.name && a.attributes == b.attributes && a.decoration == b.decoration && a.isOpen == b.isOpen)
        }
    }
}
