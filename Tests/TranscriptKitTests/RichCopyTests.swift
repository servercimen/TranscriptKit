import CoreText
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import TranscriptKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

private let markdown = """
# Title

Some **bold**, *italic*, `code`, ~~gone~~, <u>under</u> and a [link](https://example.com/a) with an ![alt](u.png) image.

- one
  - nested **item**
2. two

> quoted *words*

```swift
let x = 1
```

| a | b |
| - | - |
| 1 | 2 |

---

Math \\(x^2\\) and a [ref][r].

[r]: https://example.com/r
"""

private func font(_ text: NSAttributedString, at offset: Int) -> CTFont? {
    text.attribute(TranscriptStyle.fontKey, at: offset, effectiveRange: nil).map { $0 as! CTFont }
}

private func traits(_ text: NSAttributedString, at offset: Int) -> CTFontSymbolicTraits {
    font(text, at: offset).map { CTFontGetSymbolicTraits($0) } ?? []
}

private func offset(of string: String, in text: NSAttributedString) -> Int {
    (text.string as NSString).range(of: string).location
}

@Test func richCopyHasTheTextOfPlainCopy() {
    let document = MarkdownStreamParser.document(from: markdown)
    let style = TranscriptStyle()
    let length = document.utf16Count
    for range in [0..<length, 3..<length, 0..<20, 30..<90, 60..<(length - 4)] {
        #expect(document.copiedText(in: range, style: style).string == document.copyText(in: range))
    }
    let plain = document.copiedText(in: 0..<length, style: nil)
    var attributeCount = 0
    plain.enumerateAttributes(in: NSRange(location: 0, length: plain.length)) { attributes, _, _ in
        attributeCount += attributes.count
    }
    #expect(attributeCount == 0)
}

@Test func richCopyKeepsFontsLinksAndLines() throws {
    let document = MarkdownStreamParser.document(from: markdown)
    let style = TranscriptStyle()
    let text = document.copiedText(in: 0..<document.utf16Count, style: style)

    let body = try #require(font(text, at: offset(of: "Some", in: text)))
    let heading = try #require(font(text, at: offset(of: "Title", in: text)))
    #expect(CTFontGetSize(heading) > CTFontGetSize(body))
    #expect(traits(text, at: offset(of: "bold", in: text)).contains(.traitBold))
    #expect(traits(text, at: offset(of: "italic", in: text)).contains(.traitItalic))
    #expect(traits(text, at: offset(of: "words", in: text)).contains(.traitItalic))
    #expect(traits(text, at: offset(of: "item", in: text)).contains(.traitBold))
    #expect(traits(text, at: offset(of: "code", in: text)).contains(.traitMonoSpace))
    #expect(traits(text, at: offset(of: "let x", in: text)).contains(.traitMonoSpace))
    #expect(!traits(text, at: offset(of: "Some", in: text)).contains(.traitBold))

    let link = text.attribute(.link, at: offset(of: "link", in: text), effectiveRange: nil) as? URL
    #expect(link == URL(string: "https://example.com/a"))
    let reference = text.attribute(.link, at: offset(of: "ref", in: text), effectiveRange: nil) as? URL
    #expect(reference == URL(string: "https://example.com/r"))
    #expect(text.attribute(.link, at: offset(of: "Some", in: text), effectiveRange: nil) == nil)
    #expect(text.attribute(.strikethroughStyle, at: offset(of: "gone", in: text), effectiveRange: nil) as? Int
        == NSUnderlineStyle.single.rawValue)
    #expect(text.attribute(.underlineStyle, at: offset(of: "under", in: text), effectiveRange: nil) as? Int
        == NSUnderlineStyle.single.rawValue)
    #expect(text.attribute(.underlineStyle, at: offset(of: "Some", in: text), effectiveRange: nil) == nil)

    // Replaced and added text keeps the font of the block it is in.
    #expect(font(text, at: offset(of: "alt", in: text)) != nil)
    #expect(font(text, at: offset(of: "\\(x^2\\)", in: text)) != nil)
    #expect(font(text, at: offset(of: "- one", in: text)) != nil)
    #expect(font(text, at: offset(of: "> quoted", in: text)) != nil)
}

@Test func richCopyStylesOnlyTheSelectedPartOfASpan() {
    let document = MarkdownStreamParser.document(from: "plain **bold text** end")
    let text = document.copiedText(in: 8..<18, style: TranscriptStyle())
    #expect(text.string == "ld text en")
    #expect(traits(text, at: 0).contains(.traitBold))
    #expect(traits(text, at: 6).contains(.traitBold))
    #expect(!traits(text, at: 8).contains(.traitBold))
}

@Test func pasteboardItemHasPlainTextAndRTF() throws {
    let document = MarkdownStreamParser.document(from: markdown)
    let range = 0..<document.utf16Count
    let item = document.pasteboardItem(in: range, style: TranscriptStyle())
    #expect(Set(item.keys) == [UTType.utf8PlainText.identifier, UTType.rtf.identifier])
    #expect(item[UTType.utf8PlainText.identifier] as? String == document.copyText(in: range))
    let rtf = try #require(item[UTType.rtf.identifier] as? Data)
    #expect(String(decoding: rtf.prefix(5), as: UTF8.self) == "{\\rtf")

    #if canImport(AppKit)
    let read = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                      documentAttributes: nil)
    #expect(read.string == document.copyText(in: range))
    func readTraits(_ string: String) -> NSFontTraitMask {
        let font = read.attribute(.font, at: offset(of: string, in: read), effectiveRange: nil) as? NSFont
        return font.map { NSFontManager.shared.traits(of: $0) } ?? []
    }
    #expect(readTraits("bold").contains(.boldFontMask))
    #expect(readTraits("italic").contains(.italicFontMask))
    #expect(!readTraits("Some").contains(.boldFontMask))
    let codeFont = read.attribute(.font, at: offset(of: "let x", in: read), effectiveRange: nil) as? NSFont
    #expect(codeFont?.isFixedPitch == true)
    func readLink(_ string: String) -> String? {
        let link = read.attribute(.link, at: offset(of: string, in: read), effectiveRange: nil)
        return (link as? URL)?.absoluteString ?? link as? String
    }
    #expect(readLink("link") == "https://example.com/a")
    #expect(read.attribute(.strikethroughStyle, at: offset(of: "gone", in: read), effectiveRange: nil) as? Int
        == NSUnderlineStyle.single.rawValue)
    #expect(read.attribute(.underlineStyle, at: offset(of: "under", in: read), effectiveRange: nil) as? Int
        == NSUnderlineStyle.single.rawValue)
    #endif
}
