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
