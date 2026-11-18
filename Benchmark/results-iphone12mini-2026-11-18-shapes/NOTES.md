# iPhone 12 mini, 18 November 2026: custom tags and shapes

The library after custom tags, shapes (pills, underlines, recipes the app defines) and the 12-point side margin.
The parser and layout timings from `ParserTimingTests.swift`, run on the iPhone 12 mini (A14, iOS 27.0) and on the
Mac (Apple M2 Pro) for comparison. Both are release builds, best of 7 (parser) or 5 (layout), and each test was run
on its own: Swift Testing runs tests in parallel, which on the phone made the layout figures up to 30% higher.
Phone figures are the range over two runs; Mac figures are from one run, whose second run agreed within 0.4 µs.

On the phone:

```
TEST_RUNNER_TRANSCRIPTKIT_TIMING=1 xcodebuild test-without-building -xctestrun <release .xctestrun> \
  -destination 'platform=iOS,id=<phone>' -only-testing:'TranscriptKitDeviceTests/layoutTiming()'
```

(`TEST_RUNNER_TIMING_ONLY=tags` for the custom tag cases.) On the Mac:
`TRANSCRIPTKIT_TIMING=1 swift test -c release --no-parallel --filter layoutTiming`.

## Layout, µs per update

One update per 20 characters (about one per frame at streaming speed), at a width of 360 points.

| Text | iPhone 12 mini | Mac |
|---|---|---|
| Benchmark answer, 9,236 characters | 19.6–19.8 | 16.0 |
| One line of 3,900 characters | 32.5–33.6 | 26.4 |
| A paragraph of 3,900 characters in 54 lines | 31.9–32.1 | 26.1 |
| A paragraph with a pill and a marker stroke every few words | 32.1–32.4 | 27.2 |
| The same paragraph, its tags bold and italic, no shapes | 22.4–22.5 | 19.1 |

Shapes add about 10 µs per update on the phone (8 µs on the Mac), about 43% on this paragraph, which has a shape
every six words. The layout queue does this work, not the main thread; 32 µs is 0.2% of a 60 Hz frame.

## Parser, µs per append (two characters per append)

| Text | iPhone 12 mini | Mac |
|---|---|---|
| Benchmark answer, 9,236 characters | 3.7 | 3.4 |
| Second benchmark text, 8,166 characters | 4.8 | 4.4 |
| One line of 3,900 characters | 4.3 | 3.8 |
| A paragraph of 3,900 characters in 54 lines | 4.4–4.6 | 3.8 |
| Non-ASCII paragraph, 3,000 characters | 5.3–5.4 | 4.5 |
| Non-ASCII line, 3,000 characters | 4.6–4.7 | 3.9 |
| One line of 15,600 characters | 14.0–14.1 | 7.8 |
| A paragraph of 15,600 characters | 15.5–15.6 | 8.0 |

Custom tags (`TIMING_ONLY=tags`):

| Text | iPhone 12 mini | Mac |
|---|---|---|
| The 3,900-character paragraph, no tags | 4.4–4.5 | 3.8 |
| The same inside an open `<b>` | 5.1 | 4.4 |
| The same inside an open custom `<mark>` | 5.1 | 4.5 |
| A paragraph of closed custom tags, 4,860 characters | 4.9–5.0 | 4.3 |
| Benchmark answer with tags defined | 3.7–3.8 | 3.4 |

The phone is 10–20% slower than the Mac on everything but the 15,600-character texts, where it is about 1.9 times
slower. Those cost the most because every update copies the block's style spans and text, which grows with the block
(see `../results-parser-timing-2026-11-16/NOTES.md`). The phone's smaller caches likely make that copying cost more.
Custom tags didn't cause this: those texts have none. It is the first time they were measured on a phone.

## Checks on the phone

- All 105 tests pass on the phone (release build), including the pixel tests for shapes, the side margin and the
  streaming strip.
- In the chat sample, the `<hl>` band where a wrapped line starts with it ("on Monday") starts 7.5 px (2.5 pt) left
  of the text column, outside the view's frame, and runs from 6 px above the baseline to 11 px below: the same as in
  the simulator. In a screenshot taken while the answer was still streaming it starts at the same place; whether
  that line was then drawn in the streaming strip or already in a tile can't be told from a screenshot. The pixel
  tests cover the strip.

## Tag animations (later the same day)

The chat sample's `<hl>` boing on the same phone, Debug build of the app, release build of the tests.

- **It plays.** Instruments (Animation Hitches with Points of Interest, three launches) shows each animation as
  an interval of 1.64 to 1.67 seconds, its full length, and no hitch while it played. Each launch has a 230 to
  280 ms hitch at launch and one-frame hitches at about 3.5 and 8 seconds, outside the animation (what causes
  them wasn't looked into); one launch also had a one-frame hitch 90 ms after the animation ended.
- **A bug the phone found:** an animation could end 7 ms after it started. Text arriving right after the tag
  ("." after "Monday") changes the last letter's advance through kerning, and the check that a playing tag had
  not moved compared glyph widths too. It now compares where glyphs start; a test covers ".", ",", "'s" and words.
- **Starting an animation** (the recipe plus drawing 45 glyph images at 3x): 0.46 to 0.64 ms on the main thread.
- **Layout per update** with these changes: 32.9 µs for the paragraph with pills and markers (32.1 to 32.4 this
  morning), 22.3 to 22.4 µs for the same paragraph without shapes (22.4 to 22.5), 19.4 to 19.5 µs for the
  benchmark answer (19.6 to 19.8).
- All 117 tests pass on the phone, among them the pixel test that the animation's last frame matches the view's own
  drawing.
- Screen recording (`devicectl device capture screen-record`) is not supported on this phone, and screenshots
  take about a second each, so no screenshot caught the animation mid-way; Instruments did the checking.
