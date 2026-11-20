import CoreText
import Foundation
import Testing
@testable import TranscriptKit

private let red = TranscriptColor(red: 1, green: 0, blue: 0)

/// Colors every "let" red.
private func letHighlighter(_ code: String) -> [TranscriptCodeHighlight] {
    var marks: [TranscriptCodeHighlight] = []
    let text = code as NSString
    var search = NSRange(location: 0, length: text.length)
    while true {
        let found = text.range(of: "let", options: [], range: search)
        guard found.location != NSNotFound else { break }
        marks.append(TranscriptCodeHighlight(range: found.location..<(found.location + found.length), color: red, traits: .bold))
        let next = found.location + found.length
        search = NSRange(location: next, length: text.length - next)
    }
    return marks
}

/// Records what the highlighter was asked, in order.
private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(String, String?)] = []
    func add(_ code: String, _ language: String?) { lock.withLock { items.append((code, language)) } }
    var all: [(String, String?)] { lock.withLock { items } }
}

/// Waits until `condition` holds, for at most two seconds.
private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<200 where !condition() {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

private func codeColor(_ text: NSAttributedString, at offset: Int) -> TranscriptColor? {
    text.attribute(TranscriptStyle.foregroundKey, at: offset, effectiveRange: nil) as? TranscriptColor
}

@Test func codeBlocksTakeTheHighlightersColorsWhenTheyArrive() async {
    let store = TranscriptImageStore()
    let calls = Calls()
    store.setHighlighter { code, language in
        calls.add(code, language)
        return letHighlighter(code)
    }
    let block = MarkdownStreamParser.document(from: "```swift\nlet a = 1\nvar b = 2\n```").blocks[0]
    let style = TranscriptStyle()
    let sizing = ImageSizing(store: store, maximumWidth: 300)
    let revision = store.revision
    // The first layout asks for colors and draws the code plainly.
    #expect(codeColor(style.attributedString(for: block, images: sizing), at: 0) == nil)
    await waitUntil { store.revision > revision }
    #expect(store.revision > revision)
    let colored = style.attributedString(for: block, images: sizing)
    #expect(codeColor(colored, at: 0) == red)
    #expect(codeColor(colored, at: 10) == nil)
    #expect(calls.all.count == 1)
    #expect(calls.all.first?.1 == "swift")
    // Bold from the highlighter changes the font.
    let font = colored.attribute(TranscriptStyle.fontKey, at: 0, effectiveRange: nil) as! CTFont
    #expect(CTFontGetSymbolicTraits(font).contains(.traitBold))
}

@Test func aCodeBlockIsLaidOutAgainWhenColorsArrive() async {
    let store = TranscriptImageStore()
    store.setHighlighter { code, _ in letHighlighter(code) }
    let document = MarkdownStreamParser.document(from: "```\nlet a = 1\n```\n\nPlain text.")
    let revision = store.revision
    let first = DocumentLayout(document: document, width: 300, style: TranscriptStyle(), reusing: nil, images: store)
    #expect(first.entry(at: 0).layout.imageRevision != nil)
    #expect(first.entry(at: 1).layout.imageRevision == nil)
    await waitUntil { store.revision > revision }
    #expect(store.revision > revision)
    let second = DocumentLayout(document: document, width: 300, style: TranscriptStyle(), reusing: first, images: store)
    #expect(second.entry(at: 0).layout !== first.entry(at: 0).layout)
    #expect(second.entry(at: 1).layout === first.entry(at: 1).layout)
}

@Test func streamingCodeKeepsItsLastColorsAndHighlightsOneTextAtATime() async {
    let store = TranscriptImageStore()
    let calls = Calls()
    store.setHighlighter { code, language in
        calls.add(code, language)
        try? await Task.sleep(for: .milliseconds(100))
        return letHighlighter(code)
    }
    let texts = ["let a = 1\n", "let a = 1\nlet b", "let a = 1\nlet b = 2\nlet c"]
    // A block of the same id whose text grows, as while streaming.
    var block = MarkdownStreamParser.document(from: "```\n" + texts[0] + "```").blocks[0]
    _ = store.highlights(for: block.id, text: texts[0], language: nil)
    _ = store.highlights(for: block.id, text: texts[1], language: nil)
    _ = store.highlights(for: block.id, text: texts[2], language: nil)
    await waitUntil { calls.all.count == 2 && store.highlights(for: block.id, text: texts[2], language: nil).count == 3 }
    // The middle text was replaced by the newest while the first was highlighted.
    #expect(calls.all.map(\.0) == [texts[0], texts[2]])
    // While a newer text waits, the last colors are given for it.
    block.text = texts[2] + " = 3"
    let stale = store.highlights(for: block.id, text: block.text, language: nil)
    #expect(stale.count == 3)
}

@Test func withoutAHighlighterCodeIsNotColored() {
    let store = TranscriptImageStore()
    let block = MarkdownStreamParser.document(from: "```\nlet a = 1\n```").blocks[0]
    let text = TranscriptStyle().attributedString(for: block, images: ImageSizing(store: store, maximumWidth: 300))
    #expect(codeColor(text, at: 0) == nil)
    #expect(!store.hasHighlighter)
}

@Test func settingAHighlighterKeepsImagesThatAreLoading() async {
    let store = TranscriptImageStore()
    store.setLoader({ _ in
        try? await Task.sleep(for: .milliseconds(100))
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()
    }, onChange: nil)
    let image = TranscriptImage(source: "https://example.com/a.png", alt: "a")
    #expect(store.picture(for: image) == nil)
    store.setHighlighter { code, _ in letHighlighter(code) }
    await waitUntil { store.picture(for: image) != nil }
    #expect(store.picture(for: image) != nil)
}
