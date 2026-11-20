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
