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

/// RGBA pixels of a layout drawn at 2x on white, in black text.
private struct Drawing {
    let pixels: [UInt8]
    let width: Int
    let height: Int
    static let scale: CGFloat = 2

    init(_ layout: DocumentLayout, dark: Bool = false) {
        let width = Int((layout.width * Self.scale).rounded())
        let height = Int(((layout.height + 4) * Self.scale).rounded())
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: Self.scale, y: -Self.scale)
            let all = CGRect(x: 0, y: 0, width: layout.width, height: layout.height + 4)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(all)
            layout.draw(in: context, dirtyRect: all, text: CGColor(gray: 0, alpha: 1), codeBackground: CGColor(gray: 0.9, alpha: 1),
                        accent: CGColor(gray: 0.6, alpha: 1), dark: dark)
        }
        self.pixels = pixels
        self.width = width
        self.height = height
    }

    /// How many pixels in a rect, in layout points, are close to an RGB color (0 to 255).
    func count(in rect: CGRect, near rgb: (Int, Int, Int), tolerance: Int = 40) -> Int {
        let minX = max(Int(rect.minX * Self.scale), 0), maxX = min(Int(rect.maxX * Self.scale), width)
        let minY = max(Int(rect.minY * Self.scale), 0), maxY = min(Int(rect.maxY * Self.scale), height)
        var count = 0
        for y in minY..<max(maxY, minY) {
            for x in minX..<max(maxX, minX) {
                let i = (y * width + x) * 4
                if abs(Int(pixels[i]) - rgb.0) <= tolerance, abs(Int(pixels[i + 1]) - rgb.1) <= tolerance,
                   abs(Int(pixels[i + 2]) - rgb.2) <= tolerance { count += 1 }
            }
        }
        return count
    }
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

// MARK: Task boxes

/// The checked and the unchecked task box of a two-item task list, in layout points.
private func taskBoxes(_ layout: DocumentLayout) -> (checked: CGRect, unchecked: CGRect)? {
    guard case .checkbox(let checked, true)? = layout.entry(at: 0).layout.marker,
          case .checkbox(let unchecked, false)? = layout.entry(at: 1).layout.marker else { return nil }
    return (checked.offsetBy(dx: 0, dy: layout.entry(at: 0).y), unchecked.offsetBy(dx: 0, dy: layout.entry(at: 1).y))
}

@Test func taskBoxesTakeTheirColors() throws {
    let markdown = "- [x] done\n- [ ] open"
    let plain = layout(markdown)
    let plainBoxes = try #require(taskBoxes(plain))
    let before = Drawing(plain)
    #expect(before.count(in: plainBoxes.checked, near: (0, 122, 255)) > 20)
    #expect(before.count(in: plainBoxes.checked, near: (255, 0, 0)) == 0)
    #expect(before.count(in: plainBoxes.unchecked, near: (0, 0, 255)) == 0)

    var style = TranscriptStyle()
    style.taskCheckedColor = TranscriptColor(red: 1, green: 0, blue: 0)
    style.taskCheckmarkColor = TranscriptColor(red: 0, green: 1, blue: 0)
    style.taskUncheckedColor = TranscriptColor(red: 0, green: 0, blue: 1)
    let styled = layout(markdown, style: style)
    let styledBoxes = try #require(taskBoxes(styled))
    let after = Drawing(styled)
    #expect(after.count(in: styledBoxes.checked, near: (0, 122, 255)) == 0)
    #expect(after.count(in: styledBoxes.checked, near: (255, 0, 0)) > 20)
    #expect(after.count(in: styledBoxes.checked, near: (0, 255, 0)) > 4)
    #expect(after.count(in: styledBoxes.unchecked, near: (0, 0, 255)) > 10)
}

// MARK: Quotes

@Test func quoteTextTakesTheQuoteTextColor() throws {
    var style = TranscriptStyle()
    let gray = TranscriptColor(red: 0.5, green: 0.5, blue: 0.5)
    style.quoteTextColor = gray
    let blocks = MarkdownStreamParser.document(from: "Outside.\n\n> Inside [a link](https://x.y).\n> - item").blocks
    let outside = style.attributedString(for: blocks[0])
    #expect(outside.attribute(TranscriptStyle.foregroundKey, at: 0, effectiveRange: nil) == nil)
    let inside = style.attributedString(for: blocks[1])
    #expect(inside.attribute(TranscriptStyle.foregroundKey, at: 0, effectiveRange: nil) as? TranscriptColor == gray)
    let link = (inside.string as NSString).range(of: "a link")
    #expect(inside.attribute(TranscriptStyle.foregroundKey, at: link.location, effectiveRange: nil) as? TranscriptColor == style.linkColor)

    let drawn = DocumentLayout(document: MarkdownStreamParser.document(from: "> - item\n\n- > not quoted marker"), width: 300, style: style)
    let quotedBullet = try #require(textMarker(drawn, at: 0))
    #expect(color(of: quotedBullet.attributes) == gray)
    let plainBullet = try #require(textMarker(drawn, at: 1))
    #expect(color(of: plainBullet.attributes) == nil)
}

@Test func quoteBarsTakeTheirColorAndWidth() {
    let markdown = "> quoted text"
    let plain = layout(markdown)
    let before = Drawing(plain)
    let frame = plain.entry(at: 0).frame
    // One row of pixels across the bar.
    let row = CGRect(x: 0, y: frame.midY, width: 10, height: 0.5)
    // The bar of today: 3 points wide, in the accent gray (gray 0.6, drawn as 169 in sRGB).
    #expect(before.count(in: row, near: (169, 169, 169), tolerance: 8) == 6)

    var style = TranscriptStyle()
    style.quoteBarColor = TranscriptColor(red: 1, green: 0, blue: 0)
    style.quoteBarWidth = 6
    let styled = layout(markdown, style: style)
    let after = Drawing(styled)
    #expect(after.count(in: row, near: (169, 169, 169), tolerance: 8) == 0)
    #expect(after.count(in: row, near: (255, 0, 0), tolerance: 8) == 12)
}

@Test func aNegativeQuoteBarWidthDrawsNoBar() {
    var style = TranscriptStyle()
    style.quoteBarColor = TranscriptColor(red: 1, green: 0, blue: 0)
    style.quoteBarWidth = -6
    let drawn = layout("> > quoted text", style: style)
    let all = CGRect(x: 0, y: 0, width: drawn.width, height: drawn.height)
    #expect(Drawing(drawn).count(in: all, near: (255, 0, 0), tolerance: 8) == 0)
}

// MARK: Inline code

@Test func inlineCodeTakesItsFill() {
    let markdown = "Run `make all` now."
    let block = MarkdownStreamParser.document(from: markdown).blocks[0]
    let code = (block.text as NSString).range(of: "make all")
    let plainText = TranscriptStyle().attributedString(for: block)
    #expect(plainText.attribute(TranscriptStyle.inlineCodeBackgroundKey, at: code.location, effectiveRange: nil) == nil)

    var style = TranscriptStyle()
    let red = TranscriptColor(red: 1, green: 0, blue: 0)
    style.inlineCodeBackgroundColor = red
    style.inlineCodeCornerRadius = 2
    let styledText = style.attributedString(for: block)
    #expect(styledText.attribute(TranscriptStyle.inlineCodeBackgroundKey, at: code.location, effectiveRange: nil) as? TranscriptColor == red)
    #expect(styledText.attribute(TranscriptStyle.inlineCodeBackgroundKey, at: 0, effectiveRange: nil) == nil)

    let plain = layout(markdown)
    let styled = layout(markdown, style: style)
    let line = styled.entry(at: 0).layout.lines[0]
    let box = line.frame.offsetBy(dx: 0, dy: styled.entry(at: 0).y)
    #expect(Drawing(plain).count(in: box, near: (255, 0, 0)) == 0)
    #expect(Drawing(styled).count(in: box, near: (255, 0, 0)) > 200)
}

@Test func aTagHighlightWinsOverTheInlineCodeFill() {
    let yellow = TranscriptColor(red: 1, green: 1, blue: 0)
    let tag = TranscriptTag("mark", TranscriptDecoration(background: yellow))
    var style = TranscriptStyle()
    style.inlineCodeBackgroundColor = TranscriptColor(red: 1, green: 0, blue: 0)
    let block = MarkdownStreamParser.document(from: "<mark>`code`</mark>", tags: [tag]).blocks[0]
    let text = style.attributedString(for: block)
    #expect(text.attribute(TranscriptStyle.backgroundKey, at: 0, effectiveRange: nil) as? TranscriptColor == yellow)
    #expect(text.attribute(TranscriptStyle.inlineCodeBackgroundKey, at: 0, effectiveRange: nil) == nil)
}

// MARK: Table headers

@Test func tableHeadersTakeTheirWeight() throws {
    let markdown = "| Name | Value |\n| --- | --- |\n| a | 1 |"
    func headerFont(_ style: TranscriptStyle) -> CTFont {
        let table = layout(markdown, style: style).entry(at: 0).layout
        let run = (CTLineGetGlyphRuns(table.lines[0].ctLine) as! [CTRun])[0]
        return (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
    }
    let plain = headerFont(TranscriptStyle())
    #expect(CTFontGetSymbolicTraits(plain).contains(.traitBold))

    var style = TranscriptStyle()
    style.tableHeaderWeight = 0
    let regular = headerFont(style)
    #expect(!CTFontGetSymbolicTraits(regular).contains(.traitBold))
    style.tableHeaderWeight = 0.23
    let medium = headerFont(style)
    let weights = [plain, regular, medium].map { font -> CGFloat in
        let traits = CTFontCopyTraits(font) as NSDictionary
        return CGFloat((traits[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0)
    }
    #expect(weights[1] < weights[2] && weights[2] < weights[0])

    // The weight changes how wide the text is, so the columns are measured with it.
    let bold = layout(markdown).entry(at: 0).layout.lines[0].frame.width
    #expect(layout(markdown, style: style).entry(at: 0).layout.lines[0].frame.width < bold)
}

@Test func codeInATableHeaderKeepsTheHeaderWeight() throws {
    let markdown = "| `a` | b |\n| --- | --- |\n| c | d |"
    func codeFont(_ style: TranscriptStyle) throws -> CTFont {
        let table = layout(markdown, style: style).entry(at: 0).layout
        let run = try #require((CTLineGetGlyphRuns(table.lines[0].ctLine) as! [CTRun]).first)
        let font = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
        #expect(CTFontGetSymbolicTraits(font).contains(.traitMonoSpace))
        return font
    }
    func isBold(_ font: CTFont) -> Bool { CTFontGetSymbolicTraits(font).contains(.traitBold) }
    #expect(isBold(try codeFont(TranscriptStyle())))

    var style = TranscriptStyle()
    style.tableHeaderWeight = 0.4
    #expect(isBold(try codeFont(style)))
    style.tableHeaderWeight = 0
    #expect(!isBold(try codeFont(style)))
}

@Test func tableHeadersTakeTheirFill() throws {
    let markdown = "| Name | Value |\n| --- | --- |\n| a | 1 |"
    let plain = layout(markdown)
    let table = try #require(plain.entry(at: 0).layout.table)
    let header = CGRect(x: table.columnX[0] + 2, y: plain.entry(at: 0).y + table.rowY[0] + 2,
                        width: table.columnX[1] - table.columnX[0] - 4, height: table.rowY[1] - table.rowY[0] - 4)
    // Gray 0.9 is drawn as 232 in sRGB.
    let before = Drawing(plain)
    #expect(before.count(in: header, near: (232, 232, 232), tolerance: 4) > 100)

    var style = TranscriptStyle()
    style.tableHeaderBackgroundColor = TranscriptColor(red: 1, green: 0, blue: 0)
    let after = Drawing(layout(markdown, style: style))
    #expect(after.count(in: header, near: (232, 232, 232), tolerance: 4) == 0)
    #expect(after.count(in: header, near: (255, 0, 0), tolerance: 8) > 100)
}

// MARK: Dark appearance

@Test func shapeColorsTakeTheirDarkValues() throws {
    let markdown = "> quoted\n\n- [x] done\n- [ ] open\n\n| Name | Value |\n| --- | --- |\n| a | 1 |"
    let red = TranscriptColor(red: 1, green: 0, blue: 0)
    let green = TranscriptColor(red: 0, green: 1, blue: 0)
    var style = TranscriptStyle()
    style.quoteBarColor = TranscriptColor(light: red, dark: green)
    style.taskCheckedColor = TranscriptColor(light: red, dark: green)
    style.tableHeaderBackgroundColor = TranscriptColor(light: red, dark: green)
    let drawn = layout(markdown, style: style)
    let quote = drawn.entry(at: 0).frame
    let bar = CGRect(x: 0, y: quote.midY, width: 10, height: 0.5)
    guard case .checkbox(let box, true)? = drawn.entry(at: 1).layout.marker else {
        Issue.record("A checked task has a checkbox")
        return
    }
    let checked = box.offsetBy(dx: 0, dy: drawn.entry(at: 1).y)
    let table = try #require(drawn.entry(at: 3).layout.table)
    let header = CGRect(x: table.columnX[0] + 2, y: drawn.entry(at: 3).y + table.rowY[0] + 2,
                        width: table.columnX[1] - table.columnX[0] - 4, height: table.rowY[1] - table.rowY[0] - 4)
    for (dark, expected, other) in [(false, (255, 0, 0), (0, 255, 0)), (true, (0, 255, 0), (255, 0, 0))] {
        let pixels = Drawing(drawn, dark: dark)
        #expect(pixels.count(in: bar, near: expected, tolerance: 8) == 6, "dark: \(dark)")
        #expect(pixels.count(in: bar, near: other, tolerance: 8) == 0, "dark: \(dark)")
        #expect(pixels.count(in: checked, near: expected) > 20, "dark: \(dark)")
        #expect(pixels.count(in: checked, near: other) == 0, "dark: \(dark)")
        #expect(pixels.count(in: header, near: expected, tolerance: 8) > 100, "dark: \(dark)")
        #expect(pixels.count(in: header, near: other, tolerance: 8) == 0, "dark: \(dark)")
    }
}
