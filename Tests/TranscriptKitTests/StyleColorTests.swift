import CoreGraphics
import Foundation
import Testing
@testable import TranscriptKit

@Test func linksTakeTheStyleLinkColor() {
    var style = TranscriptStyle()
    style.linkColor = TranscriptColor(light: TranscriptColor(red: 1, green: 0, blue: 0),
                                      dark: TranscriptColor(red: 0, green: 1, blue: 0))
    let block = MarkdownStreamParser.document(from: "See [the docs](https://example.com) now.").blocks[0]
    let text = style.attributedString(for: block)
    let link = (text.string as NSString).range(of: "the docs")
    let color = text.attribute(TranscriptStyle.foregroundKey, at: link.location, effectiveRange: nil) as? TranscriptColor
    #expect(color == style.linkColor)
    #expect(text.attribute(TranscriptStyle.foregroundKey, at: 0, effectiveRange: nil) == nil)
}

@Test func aTagColorWinsOverTheLinkColor() {
    let tag = TranscriptTag("mark", TranscriptDecoration(foreground: TranscriptColor(red: 0, green: 0, blue: 1)))
    var parser = MarkdownStreamParser(tags: [tag])
    parser.append("<mark>[tagged link](https://example.com)</mark>")
    let block = parser.document.blocks[0]
    var style = TranscriptStyle()
    style.linkColor = TranscriptColor(red: 1, green: 0, blue: 0)
    let text = style.attributedString(for: block)
    let color = text.attribute(TranscriptStyle.foregroundKey, at: 0, effectiveRange: nil) as? TranscriptColor
    #expect(color == TranscriptColor(red: 0, green: 0, blue: 1))
}

private func components(_ color: CGColor) -> [CGFloat] {
    (color.components ?? []).map { ($0 * 1000).rounded() / 1000 }
}

@Test func aColorKeepsAValueForEachAppearanceAndContrast() {
    let red = TranscriptColor(red: 1, green: 0, blue: 0)
    let green = TranscriptColor(red: 0, green: 1, blue: 0)
    let blue = TranscriptColor(red: 0, green: 0, blue: 1)
    let white = TranscriptColor(red: 1, green: 1, blue: 1)
    for dark in [false, true] {
        for highContrast in [false, true] {
            #expect(components(red.cgColor(dark: dark, highContrast: highContrast)) == [1, 0, 0, 1])
        }
    }
    let color = TranscriptColor(light: red, dark: green, highContrastLight: blue, highContrastDark: white)
    #expect(components(color.cgColor(dark: false, highContrast: false)) == [1, 0, 0, 1])
    #expect(components(color.cgColor(dark: true, highContrast: false)) == [0, 1, 0, 1])
    #expect(components(color.cgColor(dark: false, highContrast: true)) == [0, 0, 1, 1])
    #expect(components(color.cgColor(dark: true, highContrast: true)) == [1, 1, 1, 1])
}

@Test func aColorMadeOfTwoKeepsTheirIncreaseContrastValues() {
    let red = TranscriptColor(red: 1, green: 0, blue: 0)
    let green = TranscriptColor(red: 0, green: 1, blue: 0)
    let blue = TranscriptColor(red: 0, green: 0, blue: 1)
    let white = TranscriptColor(red: 1, green: 1, blue: 1)
    let first = TranscriptColor(light: red, dark: red, highContrastLight: blue, highContrastDark: blue)
    let second = TranscriptColor(light: green, dark: green, highContrastLight: white, highContrastDark: white)
    let both = TranscriptColor(light: first, dark: second)
    #expect(components(both.cgColor(dark: false, highContrast: false)) == [1, 0, 0, 1])
    #expect(components(both.cgColor(dark: false, highContrast: true)) == [0, 0, 1, 1])
    #expect(components(both.cgColor(dark: true, highContrast: false)) == [0, 1, 0, 1])
    #expect(components(both.cgColor(dark: true, highContrast: true)) == [1, 1, 1, 1])
    #expect(both != TranscriptColor(light: red, dark: green))
    #expect(TranscriptColor(light: red, dark: green) == TranscriptColor(light: red, dark: green, highContrastLight: red, highContrastDark: green))
}
