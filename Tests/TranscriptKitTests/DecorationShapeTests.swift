import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import TranscriptKit

// MARK: Definitions

private let indigo = TranscriptColor(red: 0.3, green: 0.3, blue: 0.9)
private let border = TranscriptColor(red: 0.9, green: 0, blue: 0)
private let yellow = TranscriptColor(red: 1, green: 0.85, blue: 0, alpha: 0.6)

private let shapeTags: [TranscriptTag] = [
    TranscriptTag("pill") { attributes in
        TranscriptDecoration(link: attributes["id"].map { "app://\($0)" }, padding: 6,
                             shapes: [.pill(fill: indigo.opacity(0.2), border: border, borderWidth: 1)])
    },
    TranscriptTag("key", TranscriptDecoration(traits: .code, padding: 4,
                                              shapes: [.pill(border: border, borderWidth: 1, cornerRadius: 4)])),
    TranscriptTag("marker", TranscriptDecoration(shapes: [.underline(.marker, color: yellow)])),
    TranscriptTag("wave", TranscriptDecoration(shapes: [.underline(.wavy, color: border)])),
    TranscriptTag("probe", TranscriptDecoration(padding: 3, shapes: [.custom(FragmentProbe())])),
]

/// Fills each fragment's box with a color that says which ends it has.
private struct FragmentProbe: TranscriptShapeRecipe {
    static let both = TranscriptColor(red: 1, green: 0, blue: 0)
    static let start = TranscriptColor(red: 0, green: 1, blue: 0)
    static let end = TranscriptColor(red: 0, green: 0, blue: 1)
    static let middle = TranscriptColor(red: 0.5, green: 0.5, blue: 0.5)

    func paths(for fragment: TranscriptFragment) -> [TranscriptPath] {
        let color = fragment.isStart ? (fragment.isEnd ? Self.both : Self.start) : (fragment.isEnd ? Self.end : Self.middle)
        return [TranscriptPath(CGPath(rect: fragment.rect, transform: nil), fill: color)]
    }
}

private extension TranscriptColor {
    func opacity(_ alpha: CGFloat) -> TranscriptColor {
        TranscriptColor(red: light.red, green: light.green, blue: light.blue, alpha: alpha)
    }
}

private func layout(_ markdown: String, width: CGFloat = 320) -> DocumentLayout {
    DocumentLayout(document: MarkdownStreamParser.document(from: markdown, idPrefix: "d", tags: shapeTags), width: width)
}

private func decorations(_ layout: DocumentLayout) -> [LineDecorations] {
    (0..<layout.entryCount).flatMap { layout.entry(at: $0).layout.lines.compactMap(\.decorations) }
}

// MARK: Shapes and padding

@Test func paddingMakesRoomAndPillsGetTheirBox() throws {
    let padded = layout("Ask <pill id=ana>@ana</pill> now")
    let plain = layout("Ask @ana now")
    let line = padded.entry(at: 0).layout.lines[0]
    let plainLine = plain.entry(at: 0).layout.lines[0]
    // Room on both sides of the tag, and nothing else moved.
    #expect(abs(line.frame.width - plainLine.frame.width - 12) < 0.01)
    #expect(padded.document.blocks[0].text == plain.document.blocks[0].text)
    let decorations = try #require(line.decorations)
    #expect(decorations.behind.count == 2) // fill and outline
    let box = decorations.behind[0].path.boundingBoxOfPath
    let ask = CTLineGetOffsetForStringIndex(plainLine.ctLine, 4, nil)
    let after = CTLineGetOffsetForStringIndex(plainLine.ctLine, 8, nil)
    #expect(abs(box.minX - ask) <= 1)
    #expect(abs(box.maxX - (after + 12)) <= 1)
    // A tap on the padding belongs to the tag.
    let y = line.frame.midY
    #expect(padded.link(at: CGPoint(x: line.frame.minX + box.minX + 1, y: y)) == "app://ana")
    #expect(padded.link(at: CGPoint(x: line.frame.minX + box.maxX - 1, y: y)) == "app://ana")
}

@Test func aPillThatWrapsIsOpenWhereItBreaks() throws {
    let words = String(repeating: "word ", count: 30)
    let layout = layout("Lead <probe>\(words)end</probe> tail", width: 200)
    let fills = decorations(layout).flatMap(\.behind).compactMap(\.fill)
    try #require(fills.count >= 3)
    #expect(fills.first == FragmentProbe.start)
    #expect(fills.last == FragmentProbe.end)
    #expect(fills.dropFirst().dropLast().allSatisfy { $0 == FragmentProbe.middle })
    // A line the tag starts is moved over by its padding.
    let short = DocumentLayout(document: MarkdownStreamParser.document(from: "<probe>x</probe>", tags: shapeTags), width: 200)
    #expect(short.entry(at: 0).layout.lines[0].frame.minX == 3)
}

@Test func touchingPillsStaySeparate() throws {
    let layout = layout("<pill>one</pill><pill>two</pill>")
    let decorations = try #require(layout.entry(at: 0).layout.lines[0].decorations)
    let fills = decorations.behind.filter { $0.fill != nil }.map { $0.path.boundingBoxOfPath }
    #expect(fills.count == 2)
    #expect(fills[0].maxX <= fills[1].minX + 0.5)
}

@Test func anEmojiDoesNotChangeAPillsHeight() throws {
    let plain = try #require(layout("<pill>ab</pill>").entry(at: 0).layout.lines[0].decorations)
    let emoji = try #require(layout("<pill>a😀b</pill>").entry(at: 0).layout.lines[0].decorations)
    #expect(plain.behind[0].path.boundingBoxOfPath.height == emoji.behind[0].path.boundingBoxOfPath.height)
}

/// While a tag's text grows, the marker and wavy lines already drawn stay
/// put: only their end changes.
@Test(arguments: [TranscriptDecoration.Shape.LineStyle.marker, .wavy])
func linesStayPutAsTheirTextGrows(style: TranscriptDecoration.Shape.LineStyle) {
    let recipe = TranscriptDecoration.Shape.underline(style, color: yellow)
    func points(width: CGFloat) -> [CGPoint] {
        let fragment = TranscriptFragment(
            textRect: CGRect(x: 10, y: -14, width: width, height: 18), rect: CGRect(x: 10, y: -14, width: width, height: 18),
            isStart: true, isEnd: true, ascent: 14, descent: 4, xHeight: 8, capHeight: 11, underlineOffset: 2,
            underlineThickness: 1, seed: 42)
        var result: [CGPoint] = []
        for path in recipe.paths(for: fragment) {
            path.path.applyWithBlock { element in
                if element.pointee.type == .moveToPoint || element.pointee.type == .addLineToPoint {
                    result.append(element.pointee.points[0])
                }
            }
        }
        return result
    }
    let short = points(width: 120).filter { $0.x < 10 + 120 - 6 }
    let long = points(width: 200).filter { $0.x < 10 + 120 - 6 }
    #expect(!short.isEmpty)
    #expect(Set(short.map { "\($0)" }).isSubset(of: Set(long.map { "\($0)" })))
}

/// Opening a padded tag after a space at the end of a line hangs the
/// space's extra advance past the edge instead of wrapping the word before it.
@Test func paddingAfterASpaceAtTheEdgeDoesNotRewrap() {
    let words = "aaaa bbbb cccc foo"
    let measured = layout(words, width: 1000).entry(at: 0).layout.lines[0].frame.width
    let width = ceil(measured) + 1
    let before = layout(words + " t", width: width).entry(at: 0).layout
    let after = layout(words + " <pill>t", width: width).entry(at: 0).layout
    #expect(before.lines[0].range == after.lines[0].range)
    #expect(after.lines.count == 2)
    #expect(after.lines[1].frame.minX == 6)
}

// MARK: Streaming and drawing

private let streamedShapes = [
    "Ask <pill id=1>@ana</pill> and <pill id=2>@bo</pill> about <marker>the numbers that came in this week</marker>.\n\n"
        + "Press <key>⌘K</key><key>⌘F</key>, then <wave>check the long sentence that wraps over more than one line</wave> twice.\n",
    "An open <pill>pill with a line break<br>after it, and more</pill> text, <marker>a <pill>pill in a marker</pill> here</marker>.\n",
    "Two breaks <pill>in an open pill<br><br>then more</pill>, and <marker>a marker<br><br>too</marker>.\n",
    "| Who | Note |\n| --- | --- |\n| <pill id=1>@a</pill> | <marker>yes, and a long cell that wraps</marker> |\n\n- <key>item</key> one\n- <probe>two</probe>\n",
]

/// Every line's geometry and shapes, to compare two layouts.
private func signature(_ layout: DocumentLayout) -> [String] {
    (0..<layout.entryCount).flatMap { index -> [String] in
        let entry = layout.entry(at: index)
        return entry.layout.lines.map { line in
            let shapes = (line.decorations.map { $0.behind + $0.over } ?? []).map { "\($0.path.boundingBoxOfPath)" }
            return "\(entry.y) \(line.range) \(line.frame) \(shapes) \(line.decorations?.links.map(\.rect) ?? [])"
        }
    }
}

/// Laying out a stream update by update, reusing lines, gives what laying
/// out each version from scratch does, shapes and padding included.
@Test(arguments: streamedShapes)
func incrementalLayoutMatchesLayoutFromScratch(markdown: String) {
    var parser = MarkdownStreamParser(idPrefix: "s", tags: shapeTags)
    var previous: DocumentLayout?
    var mismatches: [String] = []
    for (count, character) in markdown.enumerated() {
        parser.append(String(character))
        let incremental = DocumentLayout(document: parser.document, width: 300, reusing: previous)
        let fresh = DocumentLayout(document: parser.document, width: 300)
        if signature(incremental) != signature(fresh), mismatches.count < 3 {
            mismatches.append("after \(count + 1) characters: \(parser.document.blocks.last?.text.debugDescription ?? "")")
        }
        previous = incremental
    }
    #expect(mismatches.isEmpty, "\(mismatches.joined(separator: "\n"))")
}

private func render(_ layout: DocumentLayout, bands: [ClosedRange<CGFloat>]? = nil, scale: CGFloat = 2) -> [UInt8] {
    let width = Int((layout.width * scale).rounded())
    let height = Int(((layout.height + 12) * scale).rounded())
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: scale, y: -scale)
    let all = CGRect(x: 0, y: 0, width: layout.width, height: layout.height + 12)
    func draw(_ rect: CGRect) {
        context.saveGState()
        context.clip(to: rect)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        layout.draw(in: context, dirtyRect: rect, text: CGColor(gray: 0, alpha: 1), codeBackground: CGColor(gray: 0.9, alpha: 1),
                    accent: CGColor(gray: 0.6, alpha: 1))
        context.restoreGState()
    }
    draw(all)
    for band in bands ?? [] {
        draw(CGRect(x: 0, y: band.lowerBound, width: layout.width, height: band.upperBound - band.lowerBound))
    }
    return Array(UnsafeRawBufferPointer(start: context.data!, count: width * height * 4))
}

/// Redrawing any band, or the whole layout in tiles of any height, gives
/// the pixels of drawing it in one go: shapes that reach past their line
/// are drawn again wherever they show.
@Test func redrawingAnyBandGivesTheSamePixels() {
    let markdown = streamedShapes.joined(separator: "\n") + "\n" + streamedShapes.joined(separator: "\n")
    let layout = layout(markdown, width: 300)
    let whole = render(layout)
    var bands: [ClosedRange<CGFloat>] = []
    var generator = SeededGenerator(state: 3)
    for _ in 0..<40 {
        let top = CGFloat(Int.random(in: 0..<Int(layout.height), using: &generator))
        let height = CGFloat(Int.random(in: 1...90, using: &generator))
        bands.append(top...(top + height))
    }
    for tile in [256, 97, 61] as [CGFloat] {
        var y: CGFloat = 0
        while y < layout.height { bands.append(y...(y + tile)); y += tile }
    }
    // Translucent fills cut by a clip can round a channel by one either
    // way, as in the tail tests; a shape left out or misplaced differs by far more.
    var mismatches = 0
    for band in bands {
        let redrawn = render(layout, bands: [band])
        if zip(redrawn, whole).contains(where: { abs(Int($0) - Int($1)) > 2 }) { mismatches += 1 }
    }
    #expect(mismatches == 0, "\(mismatches) of \(bands.count) bands differ")
}

@Test func pillsAndMarkersAreDrawn() {
    let drawn = render(layout("Ask <pill>@ana</pill> about <marker>these numbers</marker>."))
    var red = 0
    var yellowish = 0
    var index = 0
    while index + 3 < drawn.count {
        let (r, g, b) = (Int(drawn[index]), Int(drawn[index + 1]), Int(drawn[index + 2]))
        if r > 200, g < 60, b < 60 { red += 1 }
        if r > 230, g > 200, b < 140 { yellowish += 1 }
        index += 4
    }
    #expect(red > 100, "the pill's outline")
    #expect(yellowish > 300, "the marker")
}

@Test func shapesAreValues() {
    let a = TranscriptDecoration(padding: 4, shapes: [.pill(fill: indigo), .underline(.marker, color: yellow)])
    let b = TranscriptDecoration(padding: 4, shapes: [.pill(fill: indigo), .underline(.marker, color: yellow)])
    let c = TranscriptDecoration(padding: 4, shapes: [.pill(fill: indigo, cornerRadius: 3), .underline(.marker, color: yellow)])
    #expect(a == b)
    #expect(a != c)
    #expect(TranscriptDecoration(shapes: [.custom(FragmentProbe())]) == TranscriptDecoration(shapes: [.custom(FragmentProbe())]))
}

/// A pill that wraps is outlined along its edges only: nothing crosses it.
@Test func aWrappedPillsOutlineStaysOnItsEdges() throws {
    let layout = layout("Lead <pill>" + String(repeating: "word ", count: 20) + "end</pill> tail", width: 200)
    let drawn = render(layout)
    let rowBytes = Int((layout.width * 2).rounded()) * 4
    var checkedOpen = 0
    for index in 0..<layout.entryCount {
        let entry = layout.entry(at: index)
        for line in entry.layout.lines {
            guard let decorations = line.decorations, decorations.behind.count == 2 else { continue }
            let outline = decorations.behind[1].path
            let box = outline.boundingBoxOfPath
            var closes = false
            outline.applyWithBlock { if $0.pointee.type == .closeSubpath { closes = true } }
            if !closes { checkedOpen += 1 }
            // Every pixel between the outline's top and bottom edges, down
            // three columns: the fill, never the outline's red.
            for fraction in [0.3, 0.5, 0.7] as [CGFloat] {
                let x = line.frame.minX + box.minX + box.width * fraction
                var y = entry.y + line.baseline + box.minY + 2
                while y < entry.y + line.baseline + box.maxY - 2 {
                    let offset = Int(y * 2) * rowBytes + Int(x * 2) * 4
                    #expect(!(drawn[offset] > 200 && drawn[offset + 1] < 150), "red at \(x), \(y)")
                    y += 0.5
                }
            }
        }
    }
    #expect(checkedOpen > 0)
}

/// Pills stay inside the column wherever lines break: the padding after a
/// tag counts when the line is broken.
@Test func pillsStayInsideTheColumn() {
    let markdown = (0..<40).map { "<pill>w\(String(repeating: "o", count: $0 % 7))rd</pill>" }.joined(separator: " ")
    for width: CGFloat in [150, 173, 200, 241] {
        let layout = layout(markdown, width: width)
        let entry = layout.entry(at: 0)
        for line in entry.layout.lines {
            #expect(line.frame.minX >= 0 && line.frame.maxX <= width + 0.5)
            for path in line.decorations?.behind ?? [] {
                let ink = path.inkBounds.offsetBy(dx: line.frame.minX, dy: 0)
                #expect(ink.minX >= -0.01 && ink.maxX <= width + 0.5, "\(ink) at width \(width)")
            }
        }
    }
}

// MARK: Past the text column

/// A band from 20 points left of the text to its end: more than the
/// side overhang allows, to see where it is cut off.
private struct ReachLeft: TranscriptShapeRecipe {
    func paths(for fragment: TranscriptFragment) -> [TranscriptPath] {
        let band = CGRect(x: fragment.textRect.minX - 20, y: 0, width: fragment.textRect.maxX + 20, height: 3)
        return [TranscriptPath(CGPath(rect: band, transform: nil), fill: TranscriptColor(red: 1, green: 0, blue: 0))]
    }
}

/// Fills the area where its paths can be seen.
private struct VisibleArea: TranscriptShapeRecipe {
    func paths(for fragment: TranscriptFragment) -> [TranscriptPath] {
        [TranscriptPath(CGPath(rect: fragment.visibleRect, transform: nil), fill: TranscriptColor(red: 0, green: 0, blue: 1, alpha: 0.1))]
    }
}

@Test func shapesReachLeftOfTheTextAsFarAsTheMargin() throws {
    let tags = [TranscriptTag("reach", TranscriptDecoration(shapes: [.custom(ReachLeft())]))]
    let layout = DocumentLayout(document: MarkdownStreamParser.document(from: "<reach>Starts the line</reach> and goes on.", tags: tags),
                                width: 300)
    // Drawn with 30 points of room on the left, as a view with padding has.
    let scale: CGFloat = 2
    let room: CGFloat = 30
    let width = Int((layout.width + room) * scale)
    let height = Int((layout.height + 4) * scale)
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: scale, y: -scale)
    context.translateBy(x: room, y: 0)
    layout.draw(in: context, dirtyRect: CGRect(x: -room, y: 0, width: layout.width + room, height: layout.height),
                text: CGColor(gray: 0, alpha: 1), codeBackground: CGColor(gray: 0.9, alpha: 1), accent: CGColor(gray: 0.6, alpha: 1))
    let bytes = Array(UnsafeRawBufferPointer(start: context.data!, count: width * height * 4))
    let line = layout.entry(at: 0).layout.lines[0]
    func isRed(atX x: CGFloat) -> Bool {
        let offset = Int((line.baseline + 1.5) * scale) * width * 4 + Int((x + room) * scale) * 4
        return bytes[offset] > 200 && bytes[offset + 1] < 60
    }
    #expect(isRed(atX: -5), "left of the text, within the margin")
    #expect(isRed(atX: -11))
    #expect(!isRed(atX: -14), "past the margin, cut off")
    #expect(!isRed(atX: -19))
}

@Test func fragmentsSayWhereTheirPathsShow() throws {
    let tags = [TranscriptTag("area", TranscriptDecoration(shapes: [.custom(VisibleArea())]))]
    let side = TranscriptPath.maximumSideOverhang
    for (markdown, indent) in [("<area>plain</area>", CGFloat(0)), ("- <area>in a list item</area>", 24)] {
        let layout = DocumentLayout(document: MarkdownStreamParser.document(from: markdown, tags: tags), width: 300)
        let line = layout.entry(at: 0).layout.lines[0]
        let area = try #require(line.decorations?.behind.first?.path.boundingBoxOfPath)
        #expect(line.frame.minX == indent)
        // From the column's left edge minus the margin, to its right edge plus it.
        #expect(abs(area.minX - (-indent - side)) < 0.01)
        #expect(abs(area.width - (300 + 2 * side)) < 0.01)
        #expect(abs(area.minY - (line.frame.minY - line.baseline - TranscriptPath.maximumOverhang)) < 0.01)
    }
}
