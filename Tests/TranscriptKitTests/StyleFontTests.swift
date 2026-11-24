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

@Test func boldTextMakesEachSystemWeightHeavier() {
    let expected: [(CGFloat, CGFloat)] = [
        (-0.8, -0.4), (-0.6, 0), (-0.4, 0.23), (0, 0.3), (0.23, 0.4),
        (0.3, 0.4), (0.4, 0.56), (0.56, 0.62), (0.62, 0.62), (0.7, 0.7),
    ]
    for (weight, heavier) in expected {
        #expect(TranscriptFont.boldTextWeight(weight) == heavier)
    }
}

private func boldTextStyle(_ configure: (inout TranscriptStyle) -> Void = { _ in }) -> (off: TranscriptStyle, on: TranscriptStyle) {
    var off = TranscriptStyle()
    configure(&off)
    var on = off
    on.isBoldTextOn = true
    return (off, on)
}

@Test func boldTextMakesTheDefaultFontsHeavier() {
    let styles = boldTextStyle()
    #expect(styles.off != styles.on)
    let body = weight(styles.on.font(for: .paragraph))
    #expect(abs(body - 0.3) < 0.05)
    #expect(weight(styles.off.font(for: .paragraph)) < 0.05)
    #expect(weight(styles.on.font(for: .heading(level: 1))) > weight(styles.off.font(for: .heading(level: 1))) + 0.1)
    #expect(CTFontGetSize(styles.on.font(for: .heading(level: 1))) == CTFontGetSize(styles.off.font(for: .heading(level: 1))))
    let code = styles.on.font(for: .code(language: nil))
    #expect(CTFontGetSymbolicTraits(code).contains(.traitBold))
    #expect(!CTFontGetSymbolicTraits(styles.off.font(for: .code(language: nil))).contains(.traitBold))
    #expect(CTFontGetSymbolicTraits(styles.on.font(for: .paragraph, traits: .code)).contains(.traitBold))
}

@Test func boldTextKeepsBoldSpansHeavierThanTheText() {
    let styles = boldTextStyle()
    let body = weight(styles.on.font(for: .paragraph))
    let bold = weight(styles.on.font(for: .paragraph, traits: .bold))
    #expect(bold > body + 0.15)
    #expect(bold > weight(styles.off.font(for: .paragraph, traits: .bold)))
    let italic = styles.on.font(for: .paragraph, traits: [.bold, .italic])
    #expect(CTFontGetSymbolicTraits(italic).contains(.traitItalic))
    #expect(abs(weight(italic) - bold) < 0.05)
}

@Test func boldTextUsesTheWeightOfTheAppsSystemFont() {
    let styles = boldTextStyle { $0.bodyFont = TranscriptFont(size: 20, weight: 0.23, monospaced: true) }
    let font = styles.on.font(for: .paragraph)
    #expect(abs(weight(font) - 0.4) < 0.05)
    #expect(CTFontGetSize(font) == 20)
    #expect(CTFontGetSymbolicTraits(font).contains(.traitMonoSpace))
}

@Test func boldTextLeavesANamedFontAsItIs() {
    let styles = boldTextStyle {
        $0.bodyFont = TranscriptFont(name: "Courier", size: 20)
        $0.codeFont = TranscriptFont(name: "Menlo-Regular", size: 14)
    }
    #expect(postScriptName(styles.on.font(for: .paragraph)) == "Courier")
    #expect(postScriptName(styles.on.font(for: .code(language: nil))) == "Menlo-Regular")
    #expect(postScriptName(styles.on.font(for: .paragraph, traits: .code)) == "Menlo-Regular")
}

@Test func boldTextIsFollowedUnlessTheStyleTurnsItOff() {
    var style = TranscriptStyle()
    #expect(!style.usesBoldText)
    #expect(style.withBoldText(true).usesBoldText)
    #expect(!style.withBoldText(false).usesBoldText)
    #expect(style.withBoldText(false) == style)
    style.followsBoldText = false
    #expect(!style.withBoldText(true).usesBoldText)
    #expect(style.withBoldText(true) != style)
    let on = style.withBoldText(true).font(for: .paragraph, traits: .bold)
    let off = style.font(for: .paragraph, traits: .bold)
    #expect(postScriptName(on) == postScriptName(off))
    #expect(weight(on) == weight(off))
}

@Test func boldTextKeepsAFontThatIsAlreadyHeavyEnough() {
    var style = TranscriptStyle()
    style.isBoldTextOn = true
    let source = TranscriptFont(size: 17)
    let semibold = TranscriptFont(size: 17, weight: 0.3).makeFont()
    #expect(style.adjustedForBoldText(semibold, source: source, defaultWeight: 0, traits: []) === semibold)
    let regular = source.makeFont()
    #expect(abs(weight(style.adjustedForBoldText(regular, source: source, defaultWeight: 0, traits: [])) - 0.3) < 0.05)
    let heavy = TranscriptFont(size: 17, weight: 0.56).makeFont()
    #expect(style.adjustedForBoldText(heavy, source: nil, defaultWeight: 0, traits: .bold) === heavy)
}

@Test func theFallbackFontOfAFormulaIsCachedAndFollowsBoldText() {
    let styles = boldTextStyle()
    #expect(styles.on.mathFallbackFont(size: 14) === styles.on.mathFallbackFont(size: 14))
    #expect(CTFontGetSymbolicTraits(styles.on.mathFallbackFont(size: 14)).contains(.traitBold))
    #expect(!CTFontGetSymbolicTraits(styles.off.mathFallbackFont(size: 14)).contains(.traitBold))
    #expect(CTFontGetSize(styles.on.mathFallbackFont(size: 12)) == 12)
}

@Test func boldTextKeepsBoldCodeHeavierInASystemCodeFont() {
    let styles = boldTextStyle { $0.codeFont = TranscriptFont(size: 15, monospaced: true) }
    let code = styles.on.font(for: .code(language: nil))
    let bold = styles.on.font(for: .code(language: nil), traits: .bold)
    #expect(weight(bold) > weight(code) + 0.15)
    #expect(weight(styles.on.font(for: .paragraph, traits: [.bold, .code])) > weight(styles.on.font(for: .paragraph, traits: .code)) + 0.15)
}

@Test func boldTextStartsFromTheWeightOfListNumbersAndTableHeaders() {
    let styles = boldTextStyle()
    #expect(abs(weight(styles.on.font(for: .paragraph, weight: 0.4)) - 0.56) < 0.05)
    #expect(abs(weight(styles.on.font(for: .paragraph, weight: 0.23)) - 0.4) < 0.05)
    #expect(abs(weight(styles.off.font(for: .paragraph, weight: 0.4)) - 0.4) < 0.05)
    let named = boldTextStyle { $0.bodyFont = TranscriptFont(name: "Courier", size: 20) }
    #expect(postScriptName(named.on.font(for: .paragraph, weight: 0.4)) == postScriptName(named.off.font(for: .paragraph, weight: 0.4)))
}
