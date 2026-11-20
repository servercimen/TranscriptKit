import CoreText
import Foundation
import Testing
@testable import TranscriptKit

private func postScriptName(_ font: CTFont) -> String {
    CTFontCopyPostScriptName(font) as String
}

private func weight(_ font: CTFont) -> CGFloat {
    let traits = CTFontCopyTraits(font) as NSDictionary
    return (traits[kCTFontWeightTrait] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
}

@Test func aNamedBodyFontIsUsed() {
    var style = TranscriptStyle()
    style.bodyFont = TranscriptFont(name: "Courier", size: 20)
    let font = style.font(for: .paragraph)
    #expect(postScriptName(font) == "Courier")
    #expect(CTFontGetSize(font) == 20)
    #expect(style.effectiveBodySize == 20)
}

@Test func theSystemFontTakesItsWeight() {
    var regular = TranscriptStyle()
    regular.bodyFont = TranscriptFont(size: 17)
    var heavy = TranscriptStyle()
    heavy.bodyFont = TranscriptFont(size: 17, weight: 0.4)
    #expect(weight(heavy.font(for: .paragraph)) > weight(regular.font(for: .paragraph)) + 0.2)
}

@Test func headingLevelsPastTheEndUseTheLastFont() {
    var style = TranscriptStyle()
    style.headingFonts = [TranscriptFont(size: 30, weight: 0.3), TranscriptFont(size: 24, weight: 0.3)]
    #expect(CTFontGetSize(style.font(for: .heading(level: 1))) == 30)
    #expect(CTFontGetSize(style.font(for: .heading(level: 2))) == 24)
    #expect(CTFontGetSize(style.font(for: .heading(level: 5))) == 24)
}

@Test func inlineCodeUsesTheCodeFontDesign() {
    var style = TranscriptStyle()
    style.bodyFont = TranscriptFont(size: 20)
    style.codeFont = TranscriptFont(name: "Menlo-Regular", size: 14)
    let font = style.font(for: .paragraph, traits: .code)
    #expect(postScriptName(font) == "Menlo-Regular")
    #expect(abs(CTFontGetSize(font) - 18) < 0.01)
    #expect(postScriptName(style.font(for: .code(language: nil))) == "Menlo-Regular")
}

@Test func letterSpacingIsSetOnTheText() {
    var style = TranscriptStyle()
    style.bodyFont = TranscriptFont(size: 17, letterSpacing: 1.5)
    let block = MarkdownStreamParser.document(from: "Spaced *out* text").blocks[0]
    let text = style.attributedString(for: block)
    let kern = NSAttributedString.Key(kCTKernAttributeName as String)
    #expect(text.attribute(kern, at: 0, effectiveRange: nil) as? CGFloat == 1.5)
    #expect(text.attribute(kern, at: 8, effectiveRange: nil) as? CGFloat == 1.5)
}

@Test func aLineHeightSetsTheDistanceBetweenLines() {
    let text = String(repeating: "Words that wrap onto several lines. ", count: 6)
    let document = MarkdownStreamParser.document(from: text)
    var style = TranscriptStyle()
    style.bodyFont = TranscriptFont(size: 17, lineHeight: 40)
    let layout = DocumentLayout(document: document, width: 200, style: style)
    let lines = layout.entry(at: 0).layout.lines
    #expect(lines.count > 2)
    for index in 1..<lines.count {
        #expect(lines[index].frame.minY - lines[index - 1].frame.minY == 40)
        #expect(lines[index].baseline - lines[index - 1].baseline == 40)
    }
    #expect(lines[0].frame.height == 40)
    #expect(layout.height == CGFloat(lines.count) * 40)
}

@Test func aLineHeightBelowTheFontsOwnIsNotUsed() {
    let document = MarkdownStreamParser.document(from: "One line")
    var tight = TranscriptStyle()
    tight.bodyFont = TranscriptFont(size: 17, lineHeight: 5)
    let lines = DocumentLayout(document: document, width: 200, style: tight).entry(at: 0).layout.lines
    #expect(lines[0].frame.height > 15)
}
