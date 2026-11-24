# TranscriptKit

A native Markdown renderer for streamed text on iOS, such as a chat model's answers. It parses Markdown as it arrives,
lays it out with Core Text and draws it in one selectable text view. Parsing and layout run off the main thread, so
text streaming in at hundreds of characters a second doesn't make scrolling stutter.

![The chat sample](Examples/ChatSample/Screenshots/1-answer-top.png)

## Features

- **Streaming first.** Chunks can split anywhere, even inside a Markdown marker. Text that could still turn into
  markup is held back for a character or two, so what is on screen almost never changes style or shrinks.
- **Off the main thread.** Each frame's chunks are parsed on a background queue and laid out on another. Only the
  blocks that changed are laid out again, and the line being written is drawn on the layout queue into a surface.
  The main thread installs the result and redraws what changed.
- **One selectable document.** The whole text is one view with the system's selection handles, loupe and edit menu,
  and a selection can run from one block to the next: across headings, paragraphs, lists and code blocks.
- **Markdown:**
  - headings, paragraphs, emphasis, strikethrough and inline code;
  - nested lists, task lists and quotes;
  - fenced and indented code blocks, colored by a highlighter your app provides, and tables;
  - links, bare URLs and email addresses, and reference links;
  - images, drawn by a loader your app provides;
  - LaTeX math, drawn by a renderer your app provides;
  - HTML entities and a few HTML tags.
- **Custom tags.** Define tags such as `<mention id="ana">@Ana</mention>` and how they look: font traits, colours, a
  link, padding, and shapes drawn behind or over the text. Pills and underlines (solid, dashed, dotted, wavy,
  marker) are built in, and you can draw shapes of your own, and animate a tag's letters and shapes when it
  finishes arriving.
- **Fade-in.** Optionally, text fades in as it streams in. Core Animation plays the fades.
- **Right-to-left text.** Paragraphs in Arabic, Hebrew and other right-to-left scripts start at the right edge, and
  selection follows the glyphs in text of mixed direction.
- **SwiftUI and UIKit.** `TranscriptText` for SwiftUI, `TranscriptTextView` for UIKit.

## Requirements

iOS 17 or later, Swift 6 (Xcode 16 or later). The parser and document model also build on macOS 14, which is where
the tests run.

## Installation

Add the package with Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/servercimen/TranscriptKit.git", branch: "main"),
]
```

There are no tagged releases yet. The API may still change.

## Usage

Stream text into a `TranscriptStream` and show it with `TranscriptText`:

```swift
import SwiftUI
import TranscriptKit

struct AnswerView: View {
    @State private var stream = TranscriptStream()

    var body: some View {
        ScrollView {
            TranscriptText(stream: stream)
                .padding()
        }
        .task {
            for await chunk in model.answer() {   // your source of text
                stream.append(chunk)
            }
            stream.finish()
        }
    }
}
```

`append` only stores the text. Once per frame, everything appended since the last frame is parsed and laid out in
the background and goes straight to the view, without a SwiftUI update. SwiftUI is involved only when the text's
height changes. `finish()` shows any text that was held back in case it turned into markup.

In a `LazyVStack`, make `TranscriptText(stream:)` in the `ForEach` closure or in the view that holds the stack, not in
the `body` of a row view of its own. A lazy stack can add a row without placing it, and it can then ignore changes
inside that row. When the streamed text grows in a row that the stack has not placed, `TranscriptText` makes the view
that made it update, and SwiftUI then measures and places the row. In a row view of its own, that update stays inside
the row, and the row can stay empty.

For text that is already complete, parse it once and pass the document:

```swift
let document = MarkdownStreamParser.document(from: markdown)
TranscriptText(document, style: style)
```

### Custom tags

```swift
let tags = [
    TranscriptTag("mention") { attributes in
        TranscriptDecoration(
            traits: .bold,
            foreground: TranscriptColor(UIColor.systemIndigo),
            link: attributes["id"].map { "myapp://person/\($0)" },
            padding: 5,
            shapes: [.pill(fill: TranscriptColor(UIColor.systemIndigo.withAlphaComponent(0.1)),
                           border: TranscriptColor(UIColor.systemIndigo.withAlphaComponent(0.45)))]
        )
    },
    TranscriptTag("mark", TranscriptDecoration(
        shapes: [.underline(.marker, color: TranscriptColor(UIColor.systemYellow.withAlphaComponent(0.6)))]
    )),
]
let stream = TranscriptStream(tags: tags)
```

A tag can also show a small image before its text, such as an icon in a pill. The image takes room after the tag's
padding, so the tag's shapes surround it, and it is centred on the text's cap height. A tint fills the shape of a
template image, such as a symbol:

```swift
TranscriptTag("chip") { attributes in
    TranscriptDecoration(
        padding: 6,
        shapes: [.pill(fill: TranscriptColor(UIColor.systemGray6))],
        image: attributes["symbol"].flatMap { name in
            myIcons.cgImage(named: name).map {
                TranscriptTagImage($0, size: CGSize(width: 14, height: 14), gap: 4,
                                   tint: TranscriptColor(UIColor.secondaryLabel))
            }
        }
    )
}
```

Tags the app doesn't define show as written. For a shape of your own, implement `TranscriptShapeRecipe`. It returns
paths for each line the tag's text is on and may draw a little outside the text, up to 12 points to the sides,
past the view's edges. The chat sample has two such shapes, `Zigzag` and `SoftUnderline`, in
[`SampleTags.swift`](Examples/ChatSample/ChatSample/SampleTags.swift).

### Animated tags

A tag can also play an animation when its closing tag arrives in streamed text. Implement
`TranscriptAnimationRecipe`: from the tag's fragments, which then list their glyphs, it returns curves over time for
each glyph (offset, scale, rotation) and paths to reveal or fade in.

```swift
struct Hop: TranscriptAnimationRecipe {
    func animation(for fragments: [TranscriptFragment]) -> TranscriptAnimation {
        var animation = TranscriptAnimation()
        for (line, fragment) in fragments.enumerated() {
            for (index, glyph) in fragment.glyphs.enumerated() {
                // One letter after the other, a few points up and back.
                let start = Double(glyph.index) * 0.03
                animation.glyphs.append(.init(fragment: line, glyph: index, offsetY: .spring(peak: -4, start: start)))
            }
        }
        return animation
    }
}

TranscriptTag("hop", TranscriptDecoration(animation: .custom(Hop())))
```

Until its closing tag arrives, an animated tag shows its text without its shapes. The view then draws the tag's
glyphs and the animation's paths on Core Animation layers above the text, and draws the tag as usual again when
the animation ends, so the last frame should match that: glyphs back in place, paths fully shown. Only tags that
close while text streams in are animated, not earlier messages. Turn animations off with `animatesTags` on the view
or `.animatesTags(false)` on `TranscriptText`; with Reduce Motion on, nothing is animated. The chat sample's `Boing`
sweeps a highlighter band in under the text while each letter jumps as the band reaches it.

By default a tag's animation plays as soon as its closing tag arrives. To wait, set a timing: a tag that has closed
then waits, showing its text without its shapes, until every condition holds.

```swift
// Not before the tag is on screen and the whole answer is in:
TranscriptText(stream: stream)
    .tagAnimationTiming([.whenVisible, .afterStreamFinishes])

// Only when the app says so: each time `revealCount` changes, waiting tags play.
TranscriptText(stream: stream)
    .tagAnimationTiming(.whenRequested)
    .playTagAnimations(trigger: revealCount)
```

In UIKit, set `tagAnimationTiming` on `TranscriptTextView` and call `playTagAnimations()`. A tag that is still
waiting when it can no longer play (Reduce Motion turned on, animations turned off, the view leaving its window, a
new document) is shown as it ends up.

### Fading in text

Text that streams in can fade in. Each update's new text fades in on its own, so the fade follows the text as it
arrives. It is off by default.

```swift
TranscriptText(stream: stream)
    .fadesInText(duration: 0.3)
```

In UIKit, set `textFadeInDuration` on `TranscriptTextView`. TranscriptKit draws the new text on the layout queue,
and Core Animation plays each fade, so the main thread does no work for each frame of a fade. Glyphs and their
underline and strikethrough fade in. Backgrounds, images and formulas show at once. A tag that starts its animation
ends the fades. The fade is off with Reduce Motion, and with a line limit.

### Images

Images in the text show their alt text unless you provide a loader. The library never fetches anything itself, so
whether to load a URL from a model's answer is up to your app:

```swift
TranscriptText(stream: stream)
    .imageLoader { image in await myImageCache.cgImage(for: image.source) }
```

### Code highlighting

Code blocks show in the text color unless you provide a highlighter. It gets each code block's text and the fence's
language, and returns colored ranges in UTF-16 offsets of the code, with bold or italic if you want them. It is
called off the main thread, at most once at a time for each block, so a slow or async highlighter is fine: while
code streams in, a block keeps its newest colors on the text they were made for.

```swift
TranscriptText(stream: stream)
    .codeHighlighter { code, language in
        await myHighlighter.tokens(in: code, language: language).map { token in
            TranscriptCodeHighlight(range: token.range, color: TranscriptColor(token.color))
        }
    }
```

In UIKit, set `codeHighlighter` on `TranscriptTextView`. Colors are `TranscriptColor`s, so give them a light and a dark
value when the theme has both.

### Math

LaTeX between `\(` and `\)` is inline math. A line that starts with `\[` or `$$` starts display math, which ends at
`\]` or `$$`. Display math is a block of its own and can span lines: TranscriptKit keeps its lines as written, even a
line that starts with `-` or `#`. If a blank line comes before the closer, it is not a formula, and its lines show as
text. `$$ … $$` inside a line is display math too. A `\[` inside a line is a Markdown escape, so `\[1\]` shows `[1]`.
A single `$` is text, so prices stay as written. TranscriptKit does not read Markdown inside a formula.

Without a renderer, a formula shows its LaTeX in the code font. A renderer gets the formula and the font size of the
text around it. It returns an image, the image's size in points, and its baseline: the distance from the bottom edge
up to the baseline. TranscriptKit calls it off the main thread, once for each formula and font size.

```swift
TranscriptText(stream: stream)
    .mathRenderer { math, fontSize in
        guard let drawn = await myMathRenderer.draw(math.tex, display: math.isDisplay, fontSize: fontSize) else {
            return nil
        }
        return TranscriptMathImage(image: drawn.cgImage, size: drawn.size, baseline: drawn.descent)
    }
```

In UIKit, set `mathRenderer` on `TranscriptTextView`. TranscriptKit uses only the alpha of the image, and draws the
formula in the text color, so it follows light and dark appearance. A formula that is wider than the text column is
scaled down to fit. A paragraph that holds only display math is centered. While a formula streams in, it shows
nothing until it closes, so the text on screen only grows. Copy gives the LaTeX with its delimiters, and VoiceOver
reads the LaTeX.

### Selection

The text is selectable by default. Turn selection off for text inside a view that reacts to taps, such as a card or a
list row. A tap that is not on a link then goes to that view, and links still open:

```swift
TranscriptText(document)
    .selectable(false)
```

In UIKit, set `isSelectable` on `TranscriptTextView`.

On devices that have Writing Tools, the edit menu can offer them for the selected text, as in a `UITextView`. Turn
them off with `.showsWritingTools(false)`, or with `showsWritingTools` on `TranscriptTextView`.

### VoiceOver

VoiceOver reads the text block by block. Headings are in the rotor's list of headings, list items start with their
number or "Checked" or "Unchecked", and each link in a block is an action that opens it. The spoken words "Open %@",
"Checked", "Unchecked" and "Separator" come from your app's `Localizable.strings`, so you can translate them there.

### Line limit and alignment

For short text in cards and list rows, set a line limit and an alignment. When text is left out, the last line shown
ends in "…", and selection and copying cover only what is shown. `TranscriptText` also takes SwiftUI's modifiers:

```swift
TranscriptText(document)
    .lineLimit(2)
    .multilineTextAlignment(.center)
```

The same values are `lineLimit` and `textAlignment` on `TranscriptStyle`. The alignment moves paragraphs and headings;
lists, quotes, code and tables stay at the leading edge. A table is shown whole or not at all.

### Right-to-left text

Each block takes its direction from its first strong character, such as a letter. Digits, punctuation and spaces do
not count. So a paragraph that starts with a word in Arabic or Hebrew is right to left, and a paragraph that starts with
an English word is left to right, also when it holds words in other scripts.

In a right-to-left block, the leading edge is on the right. Lines start there, and `textAlignment` counts from there:
`.trailing` puts the lines at the left. The indents of lists and quotes, list markers and quote bars are on the right,
and a table puts its first column on the right. Code blocks are always left to right.

A selection follows the glyphs. In text of mixed direction, one line can have several selection rects, and the
handles go to the ends of the selected text. Copy gives the text in the order it was written.

### Styling

`TranscriptStyle` sets the body size, line, block and list spacing, indents, padding and the maximum image height.

To match an app's own type scale, give it fonts. Each `TranscriptFont` has a font name (nil for the system font), a
size, a weight for the system font, letter spacing and a line height. Headings take one font for each level, and
levels past the end use the last one. Inline code uses the code font's design at 0.9 times the size of the text
around it:

```swift
var style = TranscriptStyle()
style.bodyFont = TranscriptFont(size: 16, weight: 0, letterSpacing: -0.2, lineHeight: 24)
style.headingFonts = [
    TranscriptFont(size: 28, weight: 0.4, lineHeight: 34),
    TranscriptFont(size: 22, weight: 0.3, lineHeight: 28),
    TranscriptFont(size: 18, weight: 0.3, lineHeight: 24),
]
style.codeFont = TranscriptFont(name: "Menlo-Regular", size: 14, lineHeight: 20)
style.scalesWithDynamicType = true
```

A line height replaces `lineSpacing` for that kind of text, and a line is never less tall than its font needs. With
`scalesWithDynamicType`, `TranscriptText` scales every text size and line height as `UIFontMetrics` scales body text.
With `TranscriptTextView`, set `style.scaled(for: traitCollection.preferredContentSizeCategory)` yourself.

It also sets the colors. Each one is a `TranscriptColor`, with a value for light and one for dark appearance, so the
text can be drawn off the main thread. A color that is nil uses the system color shown here:

```swift
var style = TranscriptStyle()
style.textColor = TranscriptColor(UIColor.label)                     // the text
style.linkColor = TranscriptColor(UIColor.systemIndigo)              // links and their underlines
style.codeBackgroundColor = TranscriptColor(UIColor.secondarySystemFill)  // code blocks, table headers
style.accentColor = TranscriptColor(UIColor.tertiaryLabel)           // quote bars, rules, table lines
```

### Reading the selection

`onSelectionChange` tells the app when the selection changes. The range is in the document's flat UTF-16 offset
space, and it is nil when nothing is selected any more. `selectsAllWhenShown()` selects all of the text, with the
selection handles shown, when the view comes on screen:

```swift
TranscriptText(document)
    .selectsAllWhenShown()
    .onSelectionChange { range in
        if range == nil { dismiss() }    // the person tapped the selection away
    }
```

One view in a window has a selection at a time. When the person selects text in another view, the first view's
selection ends, and its range is nil. The selection stays when the person opens Share or Translate from the edit menu.

In UIKit, use `onSelectionChange`, `selectedRange` and `selectsAllWhenShown` on `TranscriptTextView`.

## In this repository

| Folder | Contents |
| --- | --- |
| `Sources/TranscriptKit` | The library |
| `Tests/TranscriptKitTests` | Unit, layout and pixel tests: `swift test` |
| [`Examples/ChatSample`](Examples/ChatSample) | A chat app that mixes streamed TranscriptKit text with native SwiftUI views (cards, charts, photos), custom tags and text beside other views |
| `Demo` | A small app for trying selection and streaming |
| `Benchmark` | A benchmark app and script that compare TranscriptKit with other renderers on the simulator and on phones, with results and notes |
| [`Docs/architecture.html`](Docs/architecture.html) | How the parser, layout and drawing work, and the measurements behind the design; download it and open it in a browser |

## License

MIT. See [LICENSE](LICENSE).
