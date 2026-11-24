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
  - fenced and indented code blocks, colored by a highlighter your app provides, which wrap or scroll sideways, and
    tables;
  - links, bare URLs and email addresses, and reference links;
  - images, drawn by a loader your app provides;
  - LaTeX math, drawn by a renderer your app provides;
  - HTML entities and a few HTML tags;
  - optionally, a single newline as a line break, as models often write it.
- **Custom tags.** Define tags such as `<mention id="ana">@Ana</mention>` and how they look: font traits, colours, a
  link, padding, and shapes drawn behind or over the text. Pills and underlines (solid, dashed, dotted, wavy,
  marker) are built in, and you can draw shapes of your own, and animate a tag's letters and shapes when it
  finishes arriving.
- **Fade-in.** Optionally, text fades in as it streams in. Core Animation plays the fades.
- **SwiftUI and UIKit.** `TranscriptText` for SwiftUI, `TranscriptTextView` for UIKit.

## Requirements

iOS 17 or later, Swift 6 (Xcode 16 or later). The parser and document model also build on macOS 14, which is where
most of the tests run.

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

### Line breaks

The parser follows CommonMark: a single newline inside a paragraph is a space. Models often use a single newline as
a line break. To show it as a line break, set `newlinesAsLineBreaks`:

```swift
let stream = TranscriptStream(newlinesAsLineBreaks: true)
let document = MarkdownStreamParser.document(from: markdown, newlinesAsLineBreaks: true)
```

The option applies to paragraphs and headings, also inside lists and quotes. A blank line still starts a new
paragraph. A line that ends in a backslash, two spaces or `<br>` also gives one line break, not two. A newline in a
code span is still a space, as in CommonMark. Selected and copied text has a newline at each such line break.

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

A pill that breaks across two lines is open where it breaks. To keep a tag on one line, set `keepsTogether: true`
in its decoration: a tag that does not fit at the end of a line then goes to the next line as a whole. A tag wider
than a line, or with a line break in it, still breaks.

A tag can also show a small image before its text, such as an icon in a pill. The image takes room after the tag's
padding, so the tag's shapes surround it, and it is centred on the text's cap height. A tag with an animation shows
its image once the animation has played; with `showsDuringAnimation: true`, the image shows from the start, while
the tag waits and while it plays. A tint fills the shape of a template image, such as a symbol:

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
paths for each line the tag's text is on and may draw a little outside the text, up to 12 points to the sides
and 6 points above and below the line, past the view's edges. The chat sample has two such shapes, `Zigzag` and `SoftUnderline`, in
[`SampleTags.swift`](Examples/ChatSample/ChatSample/SampleTags.swift).

An app can also build a tagged document without the parser. Make an `InlineSpan.CustomTag` from a tag definition,
or from a name and a decoration. Then make the span with `InlineSpan(range:tagged:)`, which also gives it the
decoration's traits and link:

```swift
let mention = InlineSpan.CustomTag(tags[0], attributes: ["id": "42"])
let document = TranscriptDocument(blocks: [
    TranscriptBlock(text: "Ask @ana now.", spans: [InlineSpan(range: 4..<8, tagged: mention)]),
])
```

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
close while text streams in are animated, not earlier messages (see below to animate text that is complete when it
is shown). Turn animations off with `animatesTags` on the view
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
waiting when it can no longer play (Reduce Motion turned on, animations turned off, a new document) is shown as it
ends up. A view that leaves its window does the same, unless the timing has `.whenVisible` or `.whenRequested`: its
tags then go on waiting until the view is back in a window. With `.whenVisible`, a view that is hidden or has an
alpha of 0, or is inside such a view, is not visible. The view looks again a short time later, at most one second
apart, so a tag can start up to one second after its view shows. When the view lays out the same text again, for
example at a new width or when an image arrives, waiting tags go on waiting and playing tags go on playing. A
playing tag whose glyphs move plays again from the start.

Text that is complete when it is shown, such as a document set directly or a page of many short texts, can animate
its tags too. With `animatesTagsInFirstText`, each tag in the first text that the view shows plays its animation
one time, as if it had just closed. The timing applies, so with `.whenVisible`, each tag plays when it comes on
screen:

```swift
TranscriptText(document)
    .animatesTagsInFirstText()
    .tagAnimationTiming(.whenVisible)
```

A view that is made again, as a lazy stack does with a row that scrolls back into view, plays them again.

Tags that wait often start at the same moment, for example when the stream finishes. To stagger them, also
implement `animation(for:in:)` in the recipe. The group gives the tag's place among the tags that start together,
in text order, and how many they are:

```swift
func animation(for fragments: [TranscriptFragment], in group: TranscriptAnimationGroup) -> TranscriptAnimation {
    var staggered = animation(for: fragments)
    let delay = Double(group.index) * 0.15
    for index in staggered.glyphs.indices {
        staggered.glyphs[index].offsetY = staggered.glyphs[index].offsetY?.delayed(by: delay)
    }
    return staggered
}
```

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
value when the theme has both, and Increase Contrast values when it has them.

### Code that does not wrap

By default, a line of code wraps at the width of the text column. Set `codeWraps` to false to keep each line of code
on one line. A code block with a line that is wider than the column then scrolls sideways in the view:

```swift
var style = TranscriptStyle()
style.codeWraps = false
TranscriptText(stream: stream, style: style)
```

The block keeps the width of the column, and only its text moves. A sideways drag that starts in the block scrolls
the block. A drag up or down still scrolls the scroll view around the text. After the drag, the block slows down as a
scroll view does. A touch on the block stops it, and does not open a link. Selection, links, copy and the selection
handles follow the scrolled text. With VoiceOver, a three-finger swipe to the left or right scrolls the block. A block
that grows while it streams keeps its offset. It also keeps its offset when the text after it changes, while the block
stays a block of the same kind. A new document starts with all blocks at their leading edge. While a block that text
streams into moves sideways, the new text shows at once, without a fade.

### Math

LaTeX between `\(` and `\)` is inline math. A line that starts with `\[` or `$$` starts display math, which ends at
`\]` or `$$`. Display math is a block of its own and can span lines: TranscriptKit keeps its lines as written, even a
line that starts with `-` or `#`. If a blank line comes before the closer, it is not a formula, and its lines show as
text. `$$ … $$` inside a line is display math too. A `\[` inside a line is a Markdown escape, so `\[1\]` shows `[1]`.
A single `$` is text, so prices stay as written. TranscriptKit does not read Markdown inside a formula.

Without a renderer, a formula shows its LaTeX in the code font. A renderer gets the formula and the font size of the
text around it. It returns an image, the image's size in points, and its baseline: the distance from the bottom edge
up to the baseline. TranscriptKit calls it off the main thread, once for each formula and font size. If it returns
nil, the formula shows its LaTeX as written once that LaTeX stays the same for a second. LaTeX that is not complete yet
can fail while it streams in, and the formula then keeps what it showed.

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
nothing until it closes, so the text on screen only grows. Copy gives the LaTeX with its delimiters.

VoiceOver reads the LaTeX by default. To give VoiceOver other words, for example from a library that turns LaTeX into
speech, set a label. TranscriptKit calls it on the main thread:

```swift
TranscriptText(stream: stream)
    .mathAccessibilityLabel { math in mySpeechText(forLaTeX: math.tex) }
```

In UIKit, set `mathAccessibilityLabel` on `TranscriptTextView`.

Two style options change display math. `displayMathAlignment` puts the formula at the leading edge, the center (the
default) or the trailing edge. With `displayMathScrolls`, a display formula that is wider than the column keeps its
size and scrolls sideways, as code that does not wrap does. When the formula shows its LaTeX, because there is no
renderer or the renderer returns nil, the LaTeX is then shown whole instead of cut with "…". Inline formulas are always
scaled down to fit.

```swift
var style = TranscriptStyle()
style.displayMathAlignment = .leading
style.displayMathScrolls = true
```

Until the renderer draws a formula, the formula is empty space of about its size. The LaTeX of a formula can change
from one update to the next, for example when your app closes an open formula in each new snapshot of the text. Then
the formula keeps its last image until the new one is drawn. Each formula has at most one drawing in progress, and
newer LaTeX replaces the LaTeX that waits for its turn. Images that arrive together cause one layout. A view keeps
the images of the formulas in the document it shows, also when the cache removes them, so it does not draw them again.

Drawn formulas are kept in a `TranscriptMathCache`. All views share `TranscriptMathCache.shared` by default, so a
formula that shows in many messages is drawn once. The cache removes the least recently used formulas when they use
more than its byte limit, 16 MB by default. The cache does not keep a nil result: each view keeps it for the formulas
it shows. A view shows the formulas that any renderer of its cache drew, so give views whose renderers draw a formula
differently a cache each:

```swift
let cache = TranscriptMathCache(byteLimit: 8 * 1024 * 1024)

TranscriptText(stream: stream)
    .mathRenderer(myRenderer, cache: cache)
```

In UIKit, set `mathCache` on `TranscriptTextView`. Setting a renderer does not empty the cache. Call `removeAll()` on
a cache after your renderer changes how it draws: the views that use the cache then draw their formulas again.

### Selection

The text is selectable by default. Turn selection off for text inside a view that reacts to taps, such as a card or a
list row. A tap that is not on a link then goes to that view, and links still open. A block that scrolls sideways
still takes the touches in it:

```swift
TranscriptText(document)
    .selectable(false)
```

In UIKit, set `isSelectable` on `TranscriptTextView`.

On devices that have Writing Tools, the edit menu can offer them for the selected text, as in a `UITextView`. Turn
them off with `.showsWritingTools(false)`, or with `showsWritingTools` on `TranscriptTextView`.

### VoiceOver

VoiceOver reads the text block by block. Headings are in the rotor's list of headings, list items start with their
number or "Checked" or "Unchecked", and each link in a block is an action that opens it. A list item also tells its
position in its list and the number of items, such as "Item 2 of 3". A table is a data table with one element for each
cell, so VoiceOver reads it cell by cell, with the row, the column and the column's header. When a table starts a list
item, its first cell reads the item's marker and tells its position. While text streams in, each block keeps its
element, so VoiceOver focus stays on its block. The view tells VoiceOver that the layout changed only when elements
come or go, or when a new layout moves them or changes their size. Text that streams into the last block does not
tell it.

Assistive technologies, such as VoiceOver, Speak Screen and Voice Control, can ask for the elements and the text from
any thread. TranscriptKit then does the work on the main thread and gives the answer to the thread that asked.

The spoken words "Open %@", "Checked", "Unchecked", "Separator" and "Item %1$ld of %2$ld" come from your app's
`Localizable.strings`, so you can translate them there.

### Line limit and alignment

For short text in cards and list rows, set a line limit and an alignment. When text is left out, the last line shown
ends in "…". The selection shows only on the text that is shown. A selection that reaches the end of that text, such as
Select All, also copies the text that is left out, and VoiceOver reads all of the text. `TranscriptText` also takes
SwiftUI's modifiers:

```swift
TranscriptText(document)
    .lineLimit(2)
    .multilineTextAlignment(.center)
```

The same values are `lineLimit` and `textAlignment` on `TranscriptStyle`. The alignment moves paragraphs and headings;
lists, quotes, code and tables stay at the leading edge. A table is shown whole or not at all.

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

The text follows the Bold Text setting. With Bold Text on, the view lays out the text again with heavier system fonts:
regular text becomes semibold, and bold text becomes heavy. The default code font takes its bold face, so bold code
then looks the same as the code around it. Set a system `codeFont`, such as
`TranscriptFont(size: 15, monospaced: true)`, to keep bold code heavier. A named font keeps its own weight. To stop the
view from making the fonts heavier, set `style.followsBoldText = false`. When you lay out a `DocumentLayout` yourself,
use `style.withBoldText(traitCollection.legibilityWeight == .bold)`, and lay out again when the setting changes. Draw
it with `highContrast: traitCollection.accessibilityContrast == .high` to use the Increase Contrast colors.

It also sets the colors. Each one is a `TranscriptColor`, with a value for light and one for dark appearance, and one
for each when Increase Contrast is on, so the text can be drawn off the main thread. `TranscriptColor(UIColor)` keeps
all four values of a dynamic color, and `TranscriptColor(light:dark:highContrastLight:highContrastDark:)` sets them
yourself. The view draws the text again when the appearance or the contrast changes. A color that is nil uses the
system color shown here:

```swift
var style = TranscriptStyle()
style.textColor = TranscriptColor(UIColor.label)                     // the text
style.linkColor = TranscriptColor(UIColor.systemIndigo)              // links and their underlines
style.codeBackgroundColor = TranscriptColor(UIColor.secondarySystemFill)  // code blocks, table headers
style.accentColor = TranscriptColor(UIColor.tertiaryLabel)           // quote bars, rules, table lines
```

To match an existing Markdown look, set how lists, task boxes, quotes, inline code and table headers look. The
defaults keep the look of today. A color that is nil uses the text color (the quote text color in a block quote), or
the value in the comment:

```swift
var style = TranscriptStyle()
style.listNumberFormat = .period                     // "1." where the Markdown wrote "1)"; .asWritten by default
style.listNumberWeight = 0.3                         // as TranscriptFont.weight; nil uses the body weight
style.listNumberColor = TranscriptColor(UIColor.secondaryLabel)
style.bullets = ["•", "–"]                           // by level; levels past the end use the last one
style.bulletColors = [TranscriptColor(UIColor.secondaryLabel)]
style.taskCheckedColor = TranscriptColor(UIColor.systemGreen)       // nil: blue
style.taskCheckmarkColor = TranscriptColor(UIColor.white)          // nil: white
style.taskUncheckedColor = TranscriptColor(UIColor.tertiaryLabel)  // nil: the text color at 45% opacity
style.quoteBarColor = TranscriptColor(UIColor.systemOrange)        // nil: accentColor
style.quoteBarWidth = 4                              // 3 by default; keep it less than quoteIndent
style.quoteTextColor = TranscriptColor(UIColor.secondaryLabel)
style.inlineCodeBackgroundColor = TranscriptColor(UIColor.tertiarySystemFill)  // nil: no fill
style.inlineCodeCornerRadius = 4
style.tableHeaderBackgroundColor = TranscriptColor(UIColor.systemGray5)       // nil: codeBackgroundColor
style.tableHeaderWeight = 0.3                        // nil: the bold body font
```

A named body font has its own weight, so a weight does not change it. For such a font, a weight of 0.3 or more uses its
bold face. Inline code in a table header uses its bold face at a header weight of 0.3 or more. Links, code colors and
custom tags' colors win over the quote text color. A custom tag's highlight wins over the inline code fill. The inline
code fill does not change where lines break.

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

### Waiting for the final content

The view lays out plain text at once only when it shows no layout yet. A style or a renderer that the app sets before
the document, on a view that has a width, makes the view lay out the empty text first. The text of the document then
shows on a later turn of the main run loop, as in the example below. Layouts of later updates, images, formulas and
code colors also come back on later turns. A snapshot or a test that does not wait for them can show no text, or the
text without them.
`contentSettled()` on `TranscriptTextView` returns when the view shows its final content. Then no layout, stream
parse, image load, formula or code colors are pending, the last layout is on screen, and its tiles are drawn:

```swift
let view = TranscriptTextView(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
view.mathRenderer = myMathRenderer
view.document = document
await view.contentSettled()
let image = UIGraphicsImageRenderer(bounds: view.bounds).image { view.layer.render(in: $0.cgContext) }
```

While a stream that has not finished goes on, `contentSettled()` returns at the first moment when nothing is pending.
A cancelled task returns at once. An image that comes back as nil counts as done. A formula that comes back as nil
counts as done when it shows its LaTeX as written, about a second later. A load, a formula or a highlight that never
ends holds back `contentSettled()`, so use a timeout or cancel the task. Give the view its size
before the call: a view with no width lays out nothing and settles at once. Fades and tag animations that play are not
waited for, so turn off `textFadeInDuration` and `animatesTags` to compare pixels.

## In this repository

| Folder | Contents |
| --- | --- |
| `Sources/TranscriptKit` | The library |
| `Tests/TranscriptKitTests` | Unit, layout and pixel tests: `swift test` |
| `Tests/TranscriptKitViewTests` | Tests of `TranscriptTextView` and `TranscriptText` on iOS: `xcodebuild test -scheme TranscriptKit -destination 'platform=iOS Simulator,name=<an iPhone>' -only-testing:TranscriptKitViewTests` |
| [`Examples/ChatSample`](Examples/ChatSample) | A chat app that mixes streamed TranscriptKit text with native SwiftUI views (cards, charts, photos), custom tags and text beside other views |
| `Demo` | A small app for trying selection and streaming |
| `Benchmark` | A benchmark app and script that compare TranscriptKit with other renderers on the simulator and on phones, with results and notes |
| [`Docs/architecture.html`](Docs/architecture.html) | How the parser, layout and drawing work, and the measurements behind the design; download it and open it in a browser |

## License

MIT. See [LICENSE](LICENSE).
