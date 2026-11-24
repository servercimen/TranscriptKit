import CoreText
import Foundation
import Testing
@testable import TranscriptKit

@Test(arguments: [
    ("Hello", WritingDirection?.some(.leftToRight)),
    ("שלום", .rightToLeft),
    ("مرحبا", .rightToLeft),
    ("123 שלום", .rightToLeft),
    ("(\"שלום\") hello", .rightToLeft),
    ("hello שלום", .leftToRight),
    ("١٢٣ abc", .leftToRight),
    ("\u{05B0}abc", .leftToRight),
    ("\u{2067}abc\u{2069} שלום", .rightToLeft),
    ("\u{200F}123", .rightToLeft),
    ("日本語", .leftToRight),
    ("123 !?", nil),
    ("", nil),
])
func firstStrongCharacterSetsTheDirection(text: String, expected: WritingDirection?) {
    #expect(DirectionScan(text).firstStrong == expected)
}

@Test func onlyTextWithRightToLeftCharactersGetsADirection() {
    #expect(DirectionScan("Plain text, 123.").paragraphDirection == nil)
    #expect(DirectionScan("Some שלום inside").paragraphDirection == .leftToRight)
    #expect(DirectionScan("שלום and more").paragraphDirection == .rightToLeft)
    // No strong character before the first right-to-left one.
    #expect(DirectionScan("12 \u{0661}\u{0662}").paragraphDirection == .leftToRight)
}

@Test func scanGoesOnFromWhereItStopped() {
    var scan = DirectionScan("12. ")
    #expect(scan.firstStrong == nil)
    scan.scan("12. שלום")
    #expect(scan.firstStrong == .rightToLeft)
    #expect(scan == DirectionScan("12. שלום"))

    var grown = DirectionScan("Text")
    grown.scan("Text and 😀 then עברית")
    #expect(grown.paragraphDirection == .leftToRight)
    #expect(grown.length == "Text and 😀 then עברית".utf16.count)
}

/// Each run's string range and position, in the order Core Text draws them.
private func runLayout(_ text: String, direction: WritingDirection?) -> [[Double]] {
    var attributes: [NSAttributedString.Key: Any] = [TranscriptStyle.fontKey: CTFontCreateUIFontForLanguage(.system, 17, nil)!]
    if let direction { attributes[TranscriptStyle.paragraphStyleKey] = direction.paragraphStyle }
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    return (CTLineGetGlyphRuns(line) as! [CTRun]).map { run in
        let range = CTRunGetStringRange(run)
        var position = CGPoint.zero
        CTRunGetPositions(run, CFRange(location: 0, length: 1), &position)
        return [Double(range.location), Double(range.length), position.x.rounded()]
    }
}

@Test(arguments: ["שלום עולם ", "123 שלום", "hello שלום world ", "(\"مرحبا\") hello", "١٢٣ abc", "\u{2067}abc\u{2069} שלום"])
func scanFindsTheDirectionThatCoreTextFinds(text: String) {
    let direction = DirectionScan(text).firstStrong
    #expect(runLayout(text, direction: nil) == runLayout(text, direction: direction))
}
