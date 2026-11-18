# iPhone 12 mini, 16 November 2026 (evening): after the parser fixes

Follows `../results-iphone12mini-2026-11-16/`, whose profile found the block parser spending about 60% of the parse
queue's time building and searching strings. Same phone, iOS 27.0, same build settings, three launches per case,
medians; only the scenarios where parsing matters. Full tables in `tables.md`, raw numbers in `results.json`.

## What changed

- **No copies while scanning a line.** The block parser's line scanner now reads the line's UTF-8 bytes and hands out
  the rest of the line as a substring. Before, it rebuilt the rest of the line as a new string from an array of
  characters, several times per line, for the line being written on every update.
- **No Foundation string searches** in the parser: single-byte searches over UTF-8 instead.
- **Ordinary text skips the hold-back rules** after one look at its first character, and the rules no longer count a
  whole line's characters.
- **A line that starts a block resumes its inline parse.** Such a block is made afresh on every update while its
  line is unfinished, and it started its inline parse from scratch each time, so a long first line (a long
  single-line paragraph, say) was parsed whole on every update. This predates the Markdown additions (it is why
  15 November's long-line figure was already 35.8 µs); the richer inline parser made it costlier. It now resumes from the last update's checkpoint, as
  every other block does. A new test feeds random markup on one long line a character at a time and compares every
  step with a fresh parse.

## Parsing cost per append (Mac, release build)

`TRANSCRIPTKIT_TIMING=1 swift test -c release --filter parserTiming`, best of 7, two characters per append.

| Text | 15 November, before the additions | 16 November, before these fixes | Now |
|---|---|---|---|
| Benchmark answer (about 9,300 characters) | 4.0 µs | 5.7 µs * | 4.5 µs |
| New benchmark text (about 8,200 characters) | – | – | 4.9 µs |
| One 3,900-character line | 35.8 µs | 66.8 µs * | 26.6 µs |

\* Measured after the first of the fixes above (the line scanner), so the cost before any of them was higher still.

## On the phone

Total CPU, all threads; `none` is the harness on its own.

| Scenario | Renderer | Before the fixes | After | 15 November |
|---|---|---|---|---|
| history | none | 1.05 | 0.99 | 1.08 |
| history | transcriptkit-stream | 4.68 | 4.58 | 4.59 |
| history | transcriptkit-uikit | 4.49 | 4.33 | 4.31 |
| history | transcriptkit (document) | 7.25 | 6.83 | 6.91 |
| burst | transcriptkit-stream | 4.40 | 4.26 | 4.26 |
| burst | transcriptkit-uikit | 4.00 | 3.84 | 3.79 |
| rich-history | transcriptkit-stream | 5.64 | 5.51 | – |
| rich-history | transcriptkit-uikit | 5.42 | 5.32 | – |
| rich-burst | transcriptkit-stream | 4.85 | 4.79 | – |
| rich-burst | transcriptkit-uikit | 4.54 | 4.51 | – |

- 1–4% less total CPU, but the control moved by up to 5% between the two runs too, so these differences alone are
  within the noise. Against 15 November, before any of the Markdown additions, the stream path on the original
  text costs about the same: 4.58 s against 4.59 s, and 4.26 s against 4.26 s. The control is 0.09 s lower than
  then in history, so with the harness taken out, TranscriptKit's own share is about 2% higher.
- Main-thread CPU did not change on the stream path (parsing is off the main thread). On the document path, where
  the benchmark parses on the main thread, it fell from 4.81 s to 4.33 s in history (15 November: 4.44 s).
- No run dropped a frame.

## Profile

Time Profiler on the phone, `transcriptkit-stream`, as before. Shares within each trace:

| | Parse queue, share of the app's samples | String work, share of the parse queue |
|---|---|---|
| Original text, before | 6.8% (353 of 5,201) | 60% |
| Original text, after | 2.8% (139 of 4,923) | 2% |
| New text, before | 7.0% (364 of 5,197) | 60% |
| New text, after | 2.8% (139 of 5,039) | 3% |

The parse queue now does about 40% of the work it did. What remains per update grows with the open paragraph: its
inline source is copied and its text rebuilt on every update (26.6 µs per append on the 3,900-character line).
