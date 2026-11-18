# Parser cost per update on long paragraphs (Mac, 16 November 2026, night)

Before this, everything the stream parser did for the block being written grew with that block: the line being
written was converted and trimmed whole, and the inline parser rebuilt the block's whole text and its style spans on
every update. Ordinary answers, with paragraphs of a few hundred characters, hardly noticed; a long paragraph did.

Measured with `TRANSCRIPTKIT_TIMING=1 swift test -c release --filter parserTiming` (best of 7, two characters per
append, Apple M2 Pro). µs per append, after each change in turn:

| Text | Start | Trim by bytes | UTF-16 once per line | Settled result kept | Line's UTF-16 kept | Spans handed out in one pass |
|---|---|---|---|---|---|---|
| Benchmark answer, 9,236 characters | 4.5 | 4.0 | 3.5 | 3.5 | 3.5 | 3.4 |
| Second benchmark text, 8,166 characters | 4.9 | 4.5 | 4.3 | 4.5 | 4.5 | 4.4 |
| One line of 3,900 characters | 26.6 | 18.2 | 15.4 | 8.0 | 4.2 | 4.1 |
| A paragraph of 3,900 characters in 54 lines | 12.4 | 12.0 | 11.9 | 4.3 | 4.3 | 4.1 |
| Non-ASCII paragraph, 3,000 characters | – | 13.5 | 13.0 | 5.0 | 5.0 | 4.9 |
| Non-ASCII line, 3,000 characters | – | 22.3 | 15.5 | 7.6 | 4.5 | 4.3 |
| One line of 15,600 characters | – | – | – | – | 9.5 | 9.1 |
| A paragraph of 15,600 characters | – | – | – | – | 9.7 | 9.3 |

The non-ASCII cases (accents, Japanese, Cyrillic, emoji) were added at the second step, so they have no first figure.

## The changes

- **Trim by bytes.** Trimming a substring's trailing space by characters walked the whole line.
- **UTF-16 once per line.** Lines are decoded from UTF-8 straight into UTF-16, and a complete line's contribution
  to its paragraph is made when the line is added, not again on every update while the paragraph is open.
- **Settled result kept.** The inline parser's checkpoint keeps the text, offsets and spans of the pieces that can no
  longer change (everything before the first piece an open delimiter, bracket or tag refers to, or the text still
  growing). A parse builds only what comes after them. When the test framework is loaded, debug builds rebuild the
  whole result as well and assert that the two are equal, so every parse in the test suite checks it; an app's debug
  build does not pay for that.
- **The line's UTF-16 kept.** The stream parser extends the UTF-16 of the line being written chunk by chunk, and the
  block parser takes a paragraph's text from it as a slice instead of converting the line again on every update.

## What is left

Per-update cost still grows a little with the paragraph: four times the length costs about 2.2 times as much
(4.1 → 9.1 µs), about 0.4 ns per character, against about 6.8 ns at the start. A profile of the 15,600-character line
puts most of it in copying, on every update, the block's style spans (about 700 on that line, each retained as it is
copied), the parser's state for the block (copied when the update parses past it) and its text. The document model
holds each block's spans as an array, which a new version cannot share with the last.

Layout runs at most once per display frame and adds about 26 µs per update for a 3,900-character paragraph, against
16 µs for the benchmark answer (`layoutTiming` in the same file).

Not measured on a phone. The phone benchmarks' paragraphs are a few hundred characters long, so they would show
little of this.
