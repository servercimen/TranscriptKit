import CoreGraphics
import Foundation
import IOSurface
import Testing
@testable import TranscriptKit

// MARK: Definitions

private let yellow = TranscriptColor(red: 1, green: 1, blue: 0)
private let blue = TranscriptColor(red: 0, green: 0, blue: 1)
private let red = TranscriptColor(red: 1, green: 0, blue: 0)

/// Yellow in light appearance, blue in dark.
private let markColor = TranscriptColor(light: yellow, dark: blue)
/// A band under the text from 6 points before it, every line: left of the
/// text column where a line starts with it.
private struct SoftBand: TranscriptShapeRecipe {
    var color: TranscriptColor

    func paths(for fragment: TranscriptFragment) -> [TranscriptPath] {
        let band = CGRect(x: fragment.textRect.minX - 6, y: -2, width: fragment.textRect.width + 12, height: 6)
        return [TranscriptPath(CGPath(roundedRect: band, cornerWidth: 3, cornerHeight: 3, transform: nil), fill: color)]
    }
}

/// Translucent, as real highlights are: one drawn twice where bands meet would show.
private let translucentMark = TranscriptColor(red: 1, green: 0.8, blue: 0, alpha: 0.4)

private let tags: [TranscriptTag] = [
    TranscriptTag("mark", TranscriptDecoration(background: markColor)),
    TranscriptTag("mention") { attributes in
        TranscriptDecoration(traits: .bold, foreground: red, link: attributes["id"].map { "app://people/\($0)" })
    },
    TranscriptTag("x-note", TranscriptDecoration(traits: .italic)),
]

private func inline(_ source: String, open: Bool = false) -> InlineParser.Result {
    InlineParser.parse(source, open: open, tags: TranscriptTag.byName(tags))
}

/// "text:tag" for each span with a custom tag.
private func tagged(_ result: InlineParser.Result) -> [String] {
    result.spans.compactMap { span in
        guard let tag = span.customTag else { return nil }
        let text = (result.text as NSString).substring(with: NSRange(location: span.range.lowerBound, length: span.range.count))
        return "\(text):\(tag.name)"
    }
}

// MARK: Parsing

@Test func customTagsDecorateTheirText() throws {
    let result = inline(#"Ask <mention id="42">@ana</mention> about the <mark>Q3 numbers</mark>."#)
    #expect(result.text == "Ask @ana about the Q3 numbers.")
    #expect(tagged(result) == ["@ana:mention", "Q3 numbers:mark"])
    let mention = try #require(result.spans.first { $0.customTag?.name == "mention" })
    #expect(mention.traits == .bold)
    #expect(mention.link == "app://people/42")
    #expect(mention.customTag?.attributes == ["id": "42"])
    #expect(mention.customTag?.decoration.foreground == red)
    let mark = try #require(result.spans.first { $0.customTag?.name == "mark" })
    #expect(mark.customTag?.decoration.background == markColor)
    #expect(mark.link == nil)
}

@Test func attributesAreReadLikeHTML() {
    func attributes(_ source: String) -> [String: String]? {
        let result = inline(source)
        return result.spans.first?.customTag?.attributes
    }
    #expect(attributes(#"<mention id="1">x</mention>"#) == ["id": "1"])
    #expect(attributes("<mention id='2'>x</mention>") == ["id": "2"])
    #expect(attributes("<mention id=3>x</mention>") == ["id": "3"])
    #expect(attributes(#"<MENTION ID = "4"  Role="admin" >x</Mention>"#) == ["id": "4", "role": "admin"])
    #expect(attributes(#"<mention id="5" id="6">x</mention>"#) == ["id": "5"])
    #expect(attributes(#"<mention title="a > b" data-x="&amp;">x</mention>"#) == ["title": "a > b", "data-x": "&amp;"])
    // "/>" opens the tag, as `<b/>` does.
    #expect(tagged(inline("<mark/>rest")) == ["rest:mark"])
    // Not tags: a bare attribute, attributes run together, no space before one.
    for source in ["<mark big>x</mark>", #"<mark a="1"b="2">x</mark>"#, #"<mark"x">y</mark>"#, "<mark a=>x</mark>"] {
        let result = inline(source)
        #expect(!result.text.isEmpty && result.text.hasPrefix("<mark"), "\(source)")
        #expect(tagged(result).isEmpty, "\(source)")
    }
}

@Test func otherTagsShowAsWritten() {
    // Not defined.
    #expect(inline("a <note>b</note> c").text == "a <note>b</note> c")
    #expect(inline("Array<Int> and Map<K, V>").text == "Array<Int> and Map<K, V>")
    #expect(InlineParser.parse("<mark>x</mark>", open: false).text == "<mark>x</mark>")
    // Names with hyphens open and close.
    #expect(tagged(inline("<x-note>aside</x-note> done")) == ["aside:x-note"])
    // Left open, a tag decorates the rest; a stray closing tag is dropped.
    #expect(tagged(inline("<mark>to the end")) == ["to the end:mark"])
    #expect(inline("text</mark> more").text == "text more")
    // Longer than 256 characters: written out, streamed or not.
    let long = "<mention id=\"" + String(repeating: "9", count: 260) + "\">x</mention>"
    #expect(inline(long).text == long.replacingOccurrences(of: "</mention>", with: ""))
    #expect(inline(long, open: true).text == inline(long).text)
    // Tags nest with each other and with Markdown.
    #expect(tagged(inline("<mark>a <mention id=1>**b**</mention> c</mark>")) == ["a b c:mark", "b:mention"])
}

@Test func customTagsCanReplaceBuiltInOnes() {
    let keycap = TranscriptTag("kbd", TranscriptDecoration(traits: .code, background: yellow))
    let result = InlineParser.parse("Press <kbd>⌘K</kbd>, <b>now</b>.", open: false, tags: TranscriptTag.byName([keycap]))
    #expect(result.text == "Press ⌘K, now.")
    #expect(result.spans.first { $0.customTag != nil }?.customTag?.decoration.background == yellow)
    #expect(result.spans.contains { $0.traits == .bold && $0.customTag == nil })
    #expect(TranscriptTag.isValidName("x-1") && !TranscriptTag.isValidName("1x") && !TranscriptTag.isValidName("a_b"))
}

@Test func tagsAreHiddenUntilTheyAreDecided() {
    #expect(inline(#"Ask <mention id="4"#, open: true).text == "Ask ")
    #expect(inline("Ask <ment", open: true).text == "Ask ")
    #expect(inline(#"Ask <mention id="42">@a"#, open: true).text == "Ask @a")
    #expect(tagged(inline(#"Ask <mention id="42">@a"#, open: true)) == ["@a:mention"])
    // A word after the name may still become an attribute; the next one decides.
    #expect(inline("Ask <mention big", open: true).text == "Ask ")
    #expect(inline("Ask <mention big deal", open: true).text == "Ask <mention big deal")
    #expect(inline("a <mark>b</ma", open: true).text == "a b")
}

// MARK: Streaming

private let streamedSamples = [
    #"Ask <mention id="42">@ana</mention> about the <mark>Q3 **numbers**</mark>, not <note>this</note>."# + "\n",
    "- <mark>first</mark> item\n- <x-note>second with a [link](https://x.y)</x-note>\n\n> <mention id=7 role='lead'>@bo</mention> said <mark>hi\n",
    "| Who | Note |\n| --- | --- |\n| <mention id=\"1\">@a</mention> | <mark>yes</mark> |\n| b | <x-note>later</x-note> |\n\nArray<Int> <mark/>end\n",
]

private func documentSteps(_ markdown: String, chunk: Int) -> [TranscriptDocument] {
    var parser = MarkdownStreamParser(idPrefix: "c", tags: tags)
    var steps: [TranscriptDocument] = []
    var rest = Substring(markdown)
    while !rest.isEmpty {
        parser.append(String(rest.prefix(chunk)))
        rest = rest.dropFirst(chunk)
        steps.append(parser.document)
    }
    parser.finish()
    steps.append(parser.document)
    return steps
}

@Test(arguments: streamedSamples)
func streamedTagsOnlyGrow(markdown: String) {
    let steps = documentSteps(markdown, chunk: 1)
    var violations: [String] = []
    for (previous, next) in zip(steps, steps.dropFirst().dropLast()) where !next.extends(previous) {
        violations.append("\(previous.blocks.last?.text.debugDescription ?? "-") -> \(next.blocks.last?.text.debugDescription ?? "-")")
    }
    #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))")
    #expect(steps.last == MarkdownStreamParser.document(from: markdown, idPrefix: "c", tags: tags))
}

@Test(arguments: streamedSamples)
func everySplitPointGivesTheSameDocument(markdown: String) {
    let whole = MarkdownStreamParser.document(from: markdown, idPrefix: "c", tags: tags)
    var mismatches: [Int] = []
    for split in 1..<markdown.count {
        var parser = MarkdownStreamParser(idPrefix: "c", tags: tags)
        parser.append(String(markdown.prefix(split)))
        parser.append(String(markdown.dropFirst(split)))
        parser.finish()
        if parser.document != whole { mismatches.append(split) }
    }
    #expect(mismatches.isEmpty, "differs when split at \(mismatches.prefix(10))")
}

/// The inline parser's resumable path, with every unit before the end
/// promised stable, as for a long line that keeps growing.
@Test func checkpointedParsesMatchAParseFromScratch() {
    let byName = TranscriptTag.byName(tags)
    for source in streamedSamples.map({ $0.replacingOccurrences(of: "\n", with: " ") }) {
        let units = Array(source.utf16)
        var checkpoint = InlineParser.Checkpoint()
        var previous = ""
        var shrank = false
        for end in 1...units.count {
            let result = InlineParser.parse(Array(units[..<end]), open: true, stableLength: end, resumingFrom: &checkpoint, tags: byName)
            if !result.text.hasPrefix(previous) { shrank = true }
            previous = result.text
        }
        #expect(!shrank, "\(source)")
        let resumed = InlineParser.parse(units, open: false, stableLength: units.count, resumingFrom: &checkpoint, tags: byName)
        #expect(resumed == InlineParser.parse(source, open: false, tags: byName), "\(source)")
    }
}

// MARK: Layout and drawing

private func layout(_ markdown: String, width: CGFloat = 320) -> DocumentLayout {
    DocumentLayout(document: MarkdownStreamParser.document(from: markdown, idPrefix: "l", tags: tags), width: width)
}

@Test func decorationLinksAreTappable() throws {
    let layout = layout(#"<mention id="42">@ana</mention> and plain text"#)
    let entry = layout.entry(at: 0)
    try #require(entry.layout.lines.count > 0)
    let line = entry.layout.lines[0]
    let y = entry.y + line.frame.midY
    #expect(layout.link(at: CGPoint(x: line.frame.minX + 8, y: y)) == "app://people/42")
    #expect(layout.link(at: CGPoint(x: line.frame.maxX - 4, y: y)) == nil)
}

private let textColor = CGColor(gray: 0, alpha: 1)

/// `layout` drawn on white, as RGBA bytes.
private func render(_ layout: DocumentLayout, dark: Bool, scale: CGFloat = 2) -> (bytes: [UInt8], width: Int) {
    let width = Int((layout.width * scale).rounded())
    let height = Int((max(layout.height, 1) * scale).rounded())
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: scale, y: -scale)
    let all = CGRect(x: 0, y: 0, width: layout.width, height: layout.height)
    layout.draw(in: context, dirtyRect: all, text: textColor, codeBackground: CGColor(gray: 0.9, alpha: 1),
                accent: CGColor(gray: 0.6, alpha: 1), dark: dark)
    return (Array(UnsafeRawBufferPointer(start: context.data!, count: width * height * 4)), width)
}

/// How many pixels are close to `color`.
private func count(_ bytes: [UInt8], near color: (UInt8, UInt8, UInt8)) -> Int {
    var total = 0
    var index = 0
    while index + 3 < bytes.count {
        if abs(Int(bytes[index]) - Int(color.0)) < 12, abs(Int(bytes[index + 1]) - Int(color.1)) < 12,
           abs(Int(bytes[index + 2]) - Int(color.2)) < 12 {
            total += 1
        }
        index += 4
    }
    return total
}

@Test func highlightsAndColorsAreDrawnForTheAppearance() {
    let marked = layout("Some <mark>highlighted words</mark> here, and <mention id=1>@ana</mention>.")
    let plain = layout("Some highlighted words here, and @ana.")
    let light = render(marked, dark: false).bytes
    let dark = render(marked, dark: true).bytes
    let none = render(plain, dark: false).bytes
    // Yellow behind the text in light appearance, blue in dark, neither without the tag.
    #expect(count(light, near: (255, 255, 0)) > 500)
    #expect(count(light, near: (0, 0, 255)) == 0)
    #expect(count(dark, near: (0, 0, 255)) > 500)
    #expect(count(none, near: (255, 255, 0)) == 0)
    // The mention's red text, which wins over a link's blue.
    #expect(count(light, near: (255, 0, 0)) > 20)
    #expect(count(light, near: (0, 122, 255)) == 0)
    // The highlight is behind the glyphs: dark text pixels remain inside it.
    #expect(count(light, near: (0, 0, 0)) > 100)
}

/// Text parsed again with another look for a tag (the way to re-theme it)
/// is drawn in the new look, also where the layout reuses earlier lines.
@Test func reparsingWithNewDecorationsRedrawsReusedLines() {
    let markdown = "<mark>" + String(repeating: "A highlight that runs over several lines of the paragraph. ", count: 4)
        + "</mark> And the end."
    let green = TranscriptColor(red: 0, green: 1, blue: 0)
    let regreened = [TranscriptTag("mark", TranscriptDecoration(background: green))]
    let first = DocumentLayout(document: MarkdownStreamParser.document(from: markdown, idPrefix: "r", tags: tags), width: 320)
    let second = MarkdownStreamParser.document(from: markdown, idPrefix: "r", tags: regreened)
    let reused = DocumentLayout(document: second, width: 320, reusing: first)
    let fresh = DocumentLayout(document: second, width: 320)
    let drawn = render(reused, dark: false).bytes
    #expect(drawn == render(fresh, dark: false).bytes)
    #expect(count(drawn, near: (0, 255, 0)) > 500)
    #expect(count(drawn, near: (255, 255, 0)) == 0)
}

private let tailColors = TailRenderer.Colors(
    text: CGColor(gray: 0, alpha: 1),
    codeBackground: CGColor(gray: 0.9, alpha: 1),
    accent: CGColor(gray: 0.6, alpha: 1)
)

private func surfaceBytes(_ surface: IOSurface, width: Int, height: Int) -> [UInt8] {
    surface.lock(options: .readOnly, seed: nil)
    defer { surface.unlock(options: .readOnly, seed: nil) }
    var result: [UInt8] = []
    for row in 0..<height {
        result.append(contentsOf: UnsafeRawBufferPointer(start: surface.baseAddress + row * surface.bytesPerRow, count: width * 4))
    }
    return result
}

/// The tail, drawn a few characters at a time off the main thread, matches
/// drawing the same layout in one go, in light and in dark appearance.
@Test(arguments: [false, true])
func streamedHighlightsMatchADrawingFromScratch(dark: Bool) {
    var colors = tailColors
    colors.dark = dark
    let scale: CGFloat = 2
    let markdown = (1...4).map { index in
        "Paragraph \(index) has <mark>a highlight that runs over the end of a line and on into the next one</mark>, "
            + "a <mention id=\"\(index)\">@person</mention>, <soft>a translucent one, also long enough to wrap</soft>, "
            + "a <pill>pill with an outline that wraps onto the next line</pill>, <marker>a marker stroke</marker>, "
            + "<reach>one that starts left of the text and wraps, so it reaches left at a line start too</reach>, "
            + "and <x-note>*an aside* <mark>inside</mark></x-note>.\n\n"
    }.joined()
    let streamedTags = tags + [
        TranscriptTag("soft", TranscriptDecoration(background: translucentMark)),
        TranscriptTag("pill", TranscriptDecoration(padding: 5, shapes: [.pill(fill: translucentMark, border: red, borderWidth: 1)])),
        TranscriptTag("marker", TranscriptDecoration(shapes: [.underline(.marker, color: markColor)])),
        TranscriptTag("reach", TranscriptDecoration(shapes: [.custom(SoftBand(color: translucentMark))])),
    ]
    var parser = MarkdownStreamParser(idPrefix: "t", tags: streamedTags)
    let renderer = TailRenderer(colors: colors, scale: scale)
    var previous: DocumentLayout?
    var rest = Substring(markdown)
    var checked = 0
    var mismatches: [String] = []
    var frameIndex = 0
    while !rest.isEmpty {
        parser.append(String(rest.prefix(3)))
        rest = rest.dropFirst(3)
        let layout = DocumentLayout(document: parser.document, width: 320, reusing: previous)
        var changedTop: CGFloat?
        var restyled: [CGRect] = []
        if let previous, layout.document.extends(previous.document) {
            (changedTop, restyled) = layout.changes(since: previous)
        }
        if let frame = renderer.render(layout, changedTop: changedTop, restyled: restyled) {
            frameIndex += 1
            if frameIndex % 9 == 0 {
                let width = Int(((layout.width + 2 * TailRenderer.sideMargin) * scale).rounded())
                let height = Int((TailRenderer.height * scale).rounded())
                let actual = surfaceBytes(frame.surface, width: width, height: height)
                let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
                context.translateBy(x: 0, y: CGFloat(height))
                context.scaleBy(x: scale, y: -scale)
                context.translateBy(x: TailRenderer.sideMargin, y: -frame.top)
                let band = CGRect(x: -TailRenderer.sideMargin, y: frame.top, width: layout.width + 2 * TailRenderer.sideMargin,
                                  height: TailRenderer.height)
                context.clip(to: band)
                layout.draw(in: context, dirtyRect: band, text: colors.text, codeBackground: colors.codeBackground,
                            accent: colors.accent, dark: dark)
                let expected = Array(UnsafeRawBufferPointer(start: context.data!, count: width * height * 4))
                let identical = actual.withUnsafeBytes { a in
                    expected.withUnsafeBytes { b in a.count == b.count && memcmp(a.baseAddress!, b.baseAddress!, a.count) == 0 }
                }
                let differing = identical ? 0 : zip(actual, expected).filter { abs(Int($0) - Int($1)) > 2 }.count
                if differing > 0, mismatches.count < 3 { mismatches.append("frame \(frameIndex): \(differing) bytes differ") }
                checked += 1
            }
        }
        previous = layout
    }
    #expect(checked > 10)
    #expect(mismatches.isEmpty, "\(mismatches.joined(separator: "\n"))")
}
