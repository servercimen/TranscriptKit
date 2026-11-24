import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import TranscriptKit

private func layout(_ markdown: String, style: TranscriptStyle = TranscriptStyle(), width: CGFloat = 300) -> DocumentLayout {
    DocumentLayout(document: MarkdownStreamParser.document(from: markdown), width: width, style: style)
}

/// The text marker of the block at `index`: its line, and the attributes of its first run.
private func textMarker(_ layout: DocumentLayout, at index: Int) -> (line: CTLine, attributes: NSDictionary)? {
    guard case .text(let line, _)? = layout.entry(at: index).layout.marker,
          let run = (CTLineGetGlyphRuns(line) as! [CTRun]).first else { return nil }
    return (line, CTRunGetAttributes(run) as NSDictionary)
}

private func weight(of attributes: NSDictionary) -> CGFloat {
    let font = attributes[kCTFontAttributeName] as! CTFont
    let traits = CTFontCopyTraits(font) as NSDictionary
    return (traits[kCTFontWeightTrait] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
}

private func color(of attributes: NSDictionary) -> TranscriptColor? {
    attributes[TranscriptStyle.foregroundKey.rawValue] as? TranscriptColor
}

// MARK: List numbers

@Test func listNumberFormatsRewriteTheDelimiter() {
    #expect(TranscriptListNumberFormat.asWritten.text(for: "3)") == "3)")
    #expect(TranscriptListNumberFormat.period.text(for: "3)") == "3.")
    #expect(TranscriptListNumberFormat.parenthesis.text(for: "12.") == "12)")
    #expect(TranscriptListNumberFormat.custom(prefix: "(", suffix: ")").text(for: "7.") == "(7)")
}

@Test func listNumbersTakeTheFormatWeightAndColor() throws {
    let markdown = "1. first\n2. second"
    let plain = try #require(textMarker(layout(markdown), at: 0))
    #expect(CTLineGetGlyphCount(plain.line) == 2)
    #expect(color(of: plain.attributes) == nil)

    var style = TranscriptStyle()
    let red = TranscriptColor(red: 1, green: 0, blue: 0)
    style.listNumberFormat = .custom(prefix: "(", suffix: ")")
    style.listNumberWeight = 0.4
    style.listNumberColor = red
    let styled = try #require(textMarker(layout(markdown, style: style), at: 1))
    #expect(CTLineGetGlyphCount(styled.line) == 3)
    #expect(color(of: styled.attributes) == red)
    #expect(weight(of: styled.attributes) > weight(of: plain.attributes))
}

@Test func aNamedBodyFontTakesItsBoldFaceForHeavyNumbers() throws {
    var style = TranscriptStyle()
    style.bodyFont = TranscriptFont(name: "Helvetica", size: 16)
    style.listNumberWeight = 0.4
    let marker = try #require(textMarker(layout("1. first", style: style), at: 0))
    let font = marker.attributes[kCTFontAttributeName] as! CTFont
    #expect(CTFontGetSymbolicTraits(font).contains(.traitBold))
    #expect(CTFontGetSize(font) == 16)
}

// MARK: Bullets

@Test func bulletsTakeTheirShapeAndColorByLevel() throws {
    let style = TranscriptStyle()
    #expect(style.bullet(at: 1).text == "•")
    #expect(style.bullet(at: 2).text == "◦")
    #expect(style.bullet(at: 5).text == "▪")
    #expect(style.bullet(at: 1).color == nil)

    var custom = TranscriptStyle()
    let red = TranscriptColor(red: 1, green: 0, blue: 0)
    let blue = TranscriptColor(red: 0, green: 0, blue: 1)
    custom.bullets = ["–", "→ "]
    custom.bulletColors = [red, blue]
    #expect(custom.bullet(at: 1).text == "–")
    #expect(custom.bullet(at: 4).text == "→ ")
    #expect(custom.bullet(at: 1).color == red)
    #expect(custom.bullet(at: 3).color == blue)
    custom.bullets = []
    #expect(custom.bullet(at: 2).text == "◦")

    custom.bullets = ["–", "→ "]
    let drawn = layout("- one\n  - two", style: custom)
    let outer = try #require(textMarker(drawn, at: 0))
    let inner = try #require(textMarker(drawn, at: 1))
    #expect(CTLineGetGlyphCount(outer.line) == 1)
    #expect(CTLineGetGlyphCount(inner.line) == 2)
    #expect(color(of: outer.attributes) == red)
    #expect(color(of: inner.attributes) == blue)
}
