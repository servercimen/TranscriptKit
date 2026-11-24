import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import TranscriptKit

/// A square of one color.
private func square(_ color: CGColor, side: Int = 28) -> CGImage {
    let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(color)
    context.fill(CGRect(x: 0, y: 0, width: side, height: side))
    return context.makeImage()!
}

private func layout(_ markdown: String, image: TranscriptTagImage?, padding: CGFloat = 0) -> DocumentLayout {
    let tag = TranscriptTag("chip", TranscriptDecoration(padding: padding, image: image))
    var parser = MarkdownStreamParser(tags: [tag])
    parser.append(markdown)
    return DocumentLayout(document: parser.document, width: 300, style: TranscriptStyle())
}

/// Where the glyph of UTF-16 offset `offset` starts in `line`, from the line's
/// origin. Not the caret offset: Core Text puts the caret halfway through the
/// spacing added after the character before, which is where a tag's room is.
private func glyphStart(_ line: BlockLayout.Line, at offset: Int) -> CGFloat {
    for run in CTLineGetGlyphRuns(line.ctLine) as! [CTRun] {
        let count = CTRunGetGlyphCount(run)
        var indices = [CFIndex](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetStringIndices(run, CFRange(location: 0, length: count), &indices)
        CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
        if let found = indices.firstIndex(of: offset - line.indexBase) { return positions[found].x }
    }
    return .nan
}

/// The same in the layout's coordinates, on the first line.
private func glyphX(_ layout: DocumentLayout, at offset: Int) -> CGFloat {
    let line = layout.entry(at: 0).layout.lines[0]
    return line.frame.minX + glyphStart(line, at: offset)
}

@Test func aTagImageMakesRoomBeforeTheText() {
    let image = TranscriptTagImage(square(CGColor(red: 1, green: 0, blue: 0, alpha: 1)), size: CGSize(width: 14, height: 14), gap: 4)
    let plain = layout("See <chip>Friday</chip> soon", image: nil, padding: 2)
    let withImage = layout("See <chip>Friday</chip> soon", image: image, padding: 2)
    // "Friday" starts at offset 4.
    #expect(abs(glyphX(withImage, at: 4) - glyphX(plain, at: 4) - 18) < 0.5)
}

@Test func aTagImageSitsBeforeTheTextOnItsCapHeight() throws {
    let image = TranscriptTagImage(square(CGColor(red: 1, green: 0, blue: 0, alpha: 1)), size: CGSize(width: 14, height: 14), gap: 4)
    let laidOut = layout("See <chip>Friday</chip> soon", image: image)
    let line = laidOut.entry(at: 0).layout.lines[0]
    let decorations = try #require(line.decorations)
    #expect(decorations.images.count == 1)
    let rect = decorations.images[0].rect
    let textStart = glyphStart(line, at: 4)
    #expect(abs(rect.maxX + 4 - textStart) < 1)
    #expect(rect.size == CGSize(width: 14, height: 14))
    let capHeight = CTFontGetCapHeight(TranscriptStyle().font(for: .paragraph))
    #expect(abs(rect.midY + capHeight / 2) < 0.5)
}

@Test func aTagImageSitsOnTheRightOfRightToLeftText() throws {
    let image = TranscriptTagImage(square(CGColor(red: 1, green: 0, blue: 0, alpha: 1)), size: CGSize(width: 14, height: 14), gap: 4)
    let plain = layout("ראה <chip>שישי</chip> בקרוב", image: nil)
    let laidOut = layout("ראה <chip>שישי</chip> בקרוב", image: image)
    let line = laidOut.entry(at: 0).layout.lines[0]
    let rect = try #require(line.decorations?.images.first).rect
    // "שישי" starts at offset 4, with its rightmost glyph. The image is
    // after that glyph, on its right, past the gap.
    let plainLine = plain.entry(at: 0).layout.lines[0]
    var advance = CGSize.zero
    for run in CTLineGetGlyphRuns(plainLine.ctLine) as! [CTRun] {
        let count = CTRunGetGlyphCount(run)
        var indices = [CFIndex](repeating: 0, count: count)
        CTRunGetStringIndices(run, CFRange(location: 0, length: count), &indices)
        if let found = indices.firstIndex(of: 4) { CTRunGetAdvances(run, CFRange(location: found, length: 1), &advance) }
    }
    #expect(advance.width > 0)
    #expect(abs(rect.minX - (glyphStart(line, at: 4) + advance.width + 4)) < 0.5)
    // The room for the image is there: the line is wider by it.
    #expect(abs(line.frame.width - plainLine.frame.width - 18) < 0.5)
}

@Test func aTagImageIsDrawn() {
    let image = TranscriptTagImage(square(CGColor(red: 1, green: 0, blue: 0, alpha: 1)), size: CGSize(width: 14, height: 14), gap: 4)
    let laidOut = layout("See <chip>Friday</chip> soon", image: image)
    let line = laidOut.entry(at: 0).layout.lines[0]
    let rect = line.decorations!.images[0].rect
    let scale: CGFloat = 2
    let width = Int((laidOut.width * scale).rounded())
    let height = Int((laidOut.height * scale).rounded())
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: scale, y: -scale)
    laidOut.draw(in: context, dirtyRect: CGRect(x: 0, y: 0, width: laidOut.width, height: laidOut.height),
                 text: CGColor(gray: 0, alpha: 1), codeBackground: CGColor(gray: 0.9, alpha: 1),
                 accent: CGColor(gray: 0.6, alpha: 1), dark: false)
    let bytes = UnsafeRawBufferPointer(start: context.data!, count: width * height * 4)
    // The image's centre, in the layout, then in the bitmap (rows from the top).
    let x = Int(((line.frame.minX + rect.midX) * scale).rounded())
    let y = Int(((laidOut.entry(at: 0).y + line.baseline + rect.midY) * scale).rounded())
    let index = (y * width + x) * 4
    #expect(bytes[index] > 200 && bytes[index + 1] < 60 && bytes[index + 2] < 60)
}

@Test func aTintedTagImageTakesTheTint() {
    let blue = TranscriptColor(red: 0, green: 0, blue: 1)
    let image = TranscriptTagImage(square(CGColor(red: 1, green: 0, blue: 0, alpha: 1)), size: CGSize(width: 14, height: 14), tint: blue)
    #expect(image.tint == blue)
    #expect(image != TranscriptTagImage(image.image, size: image.size))
}
