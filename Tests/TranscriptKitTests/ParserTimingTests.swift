import CoreGraphics
import Foundation
import Testing
@testable import TranscriptKit

// Times the stream parser per append. Opt in with TRANSCRIPTKIT_TIMING=1, in release:
//   TRANSCRIPTKIT_TIMING=1 swift test -c release --filter parserTiming
private enum TimingText {
    static func richSection(_ index: Int, definitions: Bool = true) -> String {
        let text = """
        ## Step \(index): comparing the options

        The engine keeps **one layout per block**, as the [design notes][notes-\(index)] explain, and the \
        measurements in [\(index)] back that up. Earlier figures were ~~slower~~ taken before the strip; \
        questions go to perf-\(index)@example.com or https://example.com/faq/\(index).

        | Option | Main thread | Memory | Notes |
        | :--- | ---: | ---: | :--- |
        | Tiles | 1.9 s | 41 MB | drawn on scroll |
        | Tail strip | 1.6 s | 43 MB | *off the main thread* |
        | WebView | 2.6 s | 25 MB | another process |
        | Textual | 20.0 s | 150 MB | one view per message |
        | Option \(index) | 0.\(index % 10) s | \(40 + index % 7) MB | `measured` |
        | Native views with a much longer explanation in this cell that wraps | 3.1 s | 60 MB | baseline |
        | Metal | 1.7 s | 52 MB | dropped |
        | Core Animation | 1.8 s | 47 MB | kept |

        - [x] Parse off the main thread
        - [x] Draw the growing end on the layout queue
        - [ ] Profile again on the phone
          1. Record a trace
          1. Find the &ldquo;hot&rdquo; functions &mdash; then fix them
          1. Measure &amp; compare

        > The tail strip moves down as the text grows:
        >
        > > it is drawn off the main thread, <b>in the same commit</b> as the layout,<br>so nothing tears.

        ![chart for step \(index)](https://example.com/charts/\(index).png)

        ```swift
        let layout = DocumentLayout(document: document, width: 320)
        ```

        [notes-\(index)]: https://example.com/notes/\(index) "Design notes"
        [\(index)]: https://example.com/bench/\(index)


        """
        // For experiments: the same text without the definitions.
        return definitions ? text : text.replacingOccurrences(of: "\n[notes-\(index)]: https://example.com/notes/\(index) \"Design notes\"\n[\(index)]: https://example.com/bench/\(index)\n", with: "\n")
    }

}

private func timePerAppend(_ text: String, chunk: Int, tags: [TranscriptTag] = []) -> Double {
    var parts: [String] = []
    var rest = Substring(text)
    while !rest.isEmpty { parts.append(String(rest.prefix(chunk))); rest = rest.dropFirst(chunk) }
    var best = Double.infinity
    for _ in 0..<(ProcessInfo.processInfo.environment["TIMING_LONG"] != nil ? 400 : 7) {
        var parser = MarkdownStreamParser(idPrefix: "t", tags: tags)
        let start = DispatchTime.now().uptimeNanoseconds
        for part in parts { parser.append(part) }
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        best = min(best, seconds)
    }
    return best * 1e6 / Double(parts.count)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["TRANSCRIPTKIT_TIMING"] != nil))
func parserTiming() {
    let sentence = "Some **bold** text with `code` and [a link](https://x.y) in a long line. "
    let longLine = String(String(repeating: sentence, count: 60).prefix(3900))
    // The same text as a paragraph of 54 lines, wrapped as a model might.
    let longParagraph = String(String(repeating: sentence, count: 54).split(separator: " ").enumerated()
        .map { $0.offset % 12 == 11 ? $0.element + "\n" : $0.element + " " }.joined().prefix(3900))
    switch ProcessInfo.processInfo.environment["TIMING_ONLY"] {
    case "line"?:
        print("TIMING long line: \(String(format: "%.1f", timePerAppend(longLine, chunk: 2))) µs/append")
        return
    case "verylong"?:
        let veryLong = String(String(repeating: sentence, count: 240).prefix(15600))
        print("TIMING very long line: \(String(format: "%.1f", timePerAppend(veryLong, chunk: 2))) µs/append")
        return
    case "paragraph"?:
        print("TIMING long paragraph: \(String(format: "%.1f", timePerAppend(longParagraph, chunk: 2))) µs/append")
        return
    case "tags"?:
        // Custom tags: a long paragraph left inside an open tag, against the
        // same with a built-in tag and with none, and text full of closed tags.
        let tags = [
            TranscriptTag("mark", TranscriptDecoration(background: TranscriptColor(red: 1, green: 1, blue: 0))),
            TranscriptTag("mention") { TranscriptDecoration(traits: .bold, link: $0["id"].map { "app://p/\($0)" }) },
        ]
        func time(_ text: String) -> String { String(format: "%.1f", timePerAppend(text, chunk: 2, tags: tags)) }
        print("TIMING plain paragraph: \(time(longParagraph)) µs/append")
        print("TIMING paragraph in open <b>: \(time("<b>" + longParagraph)) µs/append")
        print("TIMING paragraph in open <mark>: \(time("<mark>" + longParagraph)) µs/append")
        let tagged = String(repeating: #"Ask <mention id="42">@ana</mention> about <mark>the **Q3** numbers</mark> today. "#, count: 60)
        let taggedParagraph = tagged.split(separator: " ").enumerated()
            .map { $0.offset % 12 == 11 ? $0.element + "\n" : $0.element + " " }.joined()
        print("TIMING paragraph of closed tags (\(taggedParagraph.count) chars): \(time(taggedParagraph)) µs/append")
        let answer = (1...10).map(answerSection).joined()
        print("TIMING answer with tags defined: \(time(answer)) µs/append")
        return
    default:
        break
    }
    let answer = (1...10).map(answerSection).joined()
    let rich = (1...6).map { TimingText.richSection($0) }.joined()
    print("TIMING answer: \(answer.count) chars, 2 per append: \(String(format: "%.1f", timePerAppend(answer, chunk: 2))) µs/append")
    print("TIMING rich: \(rich.count) chars, 2 per append: \(String(format: "%.1f", timePerAppend(rich, chunk: 2))) µs/append")
    print("TIMING long line: \(longLine.count) chars, 2 per append: \(String(format: "%.1f", timePerAppend(longLine, chunk: 2))) µs/append")
    let veryLongLine = String(String(repeating: sentence, count: 240).prefix(15600))
    print("TIMING very long line: \(veryLongLine.count) chars, 2 per append: \(String(format: "%.1f", timePerAppend(veryLongLine, chunk: 2))) µs/append")
    let veryLongParagraph = String(String(repeating: sentence, count: 216).split(separator: " ").enumerated()
        .map { $0.offset % 12 == 11 ? $0.element + "\n" : $0.element + " " }.joined().prefix(15600))
    print("TIMING very long paragraph: \(veryLongParagraph.count) chars, 2 per append: \(String(format: "%.1f", timePerAppend(veryLongParagraph, chunk: 2))) µs/append")
    print("TIMING long paragraph: \(longParagraph.count) chars in \(longParagraph.split(separator: "\n").count) lines, 2 per append: \(String(format: "%.1f", timePerAppend(longParagraph, chunk: 2))) µs/append")
    let mixed = "Café **crème**, 日本語の`コード` and [ссылка](https://x.y) 👩‍💻 éé. "
    let mixedParagraph = String(String(repeating: mixed, count: 70).split(separator: " ").enumerated()
        .map { $0.offset % 10 == 9 ? $0.element + "\n" : $0.element + " " }.joined().prefix(3000))
    print("TIMING non-ASCII paragraph: \(mixedParagraph.count) chars, 2 per append: \(String(format: "%.1f", timePerAppend(mixedParagraph, chunk: 2))) µs/append")
    let mixedLine = String(String(repeating: mixed, count: 70).prefix(3000))
    print("TIMING non-ASCII line: \(mixedLine.count) chars, 2 per append: \(String(format: "%.1f", timePerAppend(mixedLine, chunk: 2))) µs/append")
}

/// Layout per update on the same long texts: how much of an update's cost the
/// layout queue adds after parsing.
@Test(.enabled(if: ProcessInfo.processInfo.environment["TRANSCRIPTKIT_TIMING"] != nil))
func layoutTiming() {
    let sentence = "Some **bold** text with `code` and [a link](https://x.y) in a long line. "
    let line = String(String(repeating: sentence, count: 60).prefix(3900))
    let paragraph = String(String(repeating: sentence, count: 54).split(separator: " ").enumerated()
        .map { $0.offset % 12 == 11 ? $0.element + "\n" : $0.element + " " }.joined().prefix(3900))
    // The same paragraph with a pill or a marker stroke every few words.
    let shaped = String(String(repeating: "Ask <pill>@ana</pill> about <marker>the Q3 numbers</marker> and the rest of the text. ",
                               count: 54).split(separator: " ").enumerated()
        .map { $0.offset % 12 == 11 ? $0.element + "\n" : $0.element + " " }.joined().prefix(5200))
    let shapeTags = [
        TranscriptTag("pill", TranscriptDecoration(padding: 5, shapes: [.pill(fill: TranscriptColor(red: 0.3, green: 0.3, blue: 0.9, alpha: 0.15),
                                                                           border: TranscriptColor(red: 0.3, green: 0.3, blue: 0.9))])),
        TranscriptTag("marker", TranscriptDecoration(shapes: [.underline(.marker, color: TranscriptColor(red: 1, green: 0.85, blue: 0, alpha: 0.6))])),
    ]
    for (name, text, tags) in [("long line", line, []), ("long paragraph", paragraph, []), ("answer", (1...10).map(answerSection).joined(), []),
                               ("paragraph with pills and markers", shaped, shapeTags),
                               ("same paragraph, tags without shapes", shaped,
                                [TranscriptTag("pill", TranscriptDecoration(traits: .bold)), TranscriptTag("marker", TranscriptDecoration(traits: .italic))])] {
        // Documents as a stream produces them, one per 20 characters (about one per frame).
        var parser = MarkdownStreamParser(idPrefix: "t", tags: tags)
        var documents: [TranscriptDocument] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            parser.append(String(rest.prefix(20)))
            rest = rest.dropFirst(20)
            documents.append(parser.document)
        }
        var best = Double.infinity
        for _ in 0..<5 {
            var previous: DocumentLayout?
            let start = DispatchTime.now().uptimeNanoseconds
            for document in documents { previous = DocumentLayout(document: document, width: 360, reusing: previous) }
            best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
        }
        print("LAYOUT \(name): \(String(format: "%.1f", best * 1e6 / Double(documents.count))) µs per update, \(documents.count) updates")
    }
}


/// What starting a tag's animation costs the main thread: asking the recipe
/// for the animation and drawing each glyph and path into its image.
@Test(.enabled(if: ProcessInfo.processInfo.environment["TRANSCRIPTKIT_TIMING"] != nil))
func animationStartTiming() throws {
    struct Jump: TranscriptAnimationRecipe {
        func animation(for fragments: [TranscriptFragment]) -> TranscriptAnimation {
            var animation = TranscriptAnimation()
            for (line, fragment) in fragments.enumerated() {
                for index in fragment.glyphs.indices {
                    let jump = TranscriptCurve.spring(peak: -3, start: Double(index) * 0.02)
                    animation.glyphs.append(.init(fragment: line, glyph: index, offsetY: jump, scaleX: jump.map { 1 + $0 / 60 },
                                                  scaleY: jump.map { 1 - $0 / 60 }))
                }
            }
            return animation
        }
    }
    let band = TranscriptDecoration.Shape.underline(.marker, color: TranscriptColor(red: 1, green: 0.8, blue: 0, alpha: 0.4))
    let tags = [TranscriptTag("hl", TranscriptDecoration(shapes: [band], animation: .custom(Jump())))]
    let text = "Fixed the <hl>login timeouts that support flagged on Monday</hl>, then took the rest."
    let layout = DocumentLayout(document: MarkdownStreamParser.document(from: text, idPrefix: "t", tags: tags), width: 300)
    let tag = try #require(layout.animatedTag(TagKey(block: "t-0", start: 10, name: "hl")))
    var best = (recipe: Double.infinity, sprites: Double.infinity, layers: Double.infinity)
    var count = 0
    for _ in 0..<20 {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let animation = tag.animation.animation(for: tag.fragments)
        let t1 = DispatchTime.now().uptimeNanoseconds
        let sprites = TagAnimationPlayer.sprites(for: tag, animation: animation,
                                                 appearance: .init(text: CGColor(gray: 0, alpha: 1), dark: false, scale: 3))
        let t2 = DispatchTime.now().uptimeNanoseconds
        let layer = TagAnimationPlayer.makeLayer(sprites: sprites, animation: animation, scale: 3, beginTime: 0)
        let t3 = DispatchTime.now().uptimeNanoseconds
        count = layer.sublayers?.count ?? 0
        best = (min(best.recipe, Double(t1 - t0) / 1e3), min(best.sprites, Double(t2 - t1) / 1e3), min(best.layers, Double(t3 - t2) / 1e3))
    }
    print("ANIMATION start, \(count) layers (45 characters on 2 lines, 3x): recipe \(String(format: "%.0f", best.recipe)) µs, " +
          "images \(String(format: "%.0f", best.sprites)) µs, layers \(String(format: "%.0f", best.layers)) µs")
}
