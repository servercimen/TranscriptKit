# iPhone 12 mini, 18 November 2026 (evening): after custom tags, shapes and animations

Everything added since `../results-iphone12mini-2026-11-16-parser/`: custom tags, shapes, the 12-point side margin
(tiles and the tail strip 24 points wider than the view), tag animations and their timing. Same phone, iOS 27.0,
same build settings, three launches per case, medians; thermal state nominal in every run. Full tables in
`tables.md`, raw numbers in `results.json`. The benchmark text has no custom tags, so this measures what the
changes cost everything else.

## Benchmark

| Scenario | Renderer | Main CPU s (16 Nov → now) | Process CPU s | Peak MB |
|---|---|---|---|---|
| history | none | 0.36 → 0.38 | 0.99 → 1.06 | 11 → 11 |
| history | transcriptkit-stream | 1.86 → 1.91 | 4.58 → 4.71 | 63 → 66 |
| history | transcriptkit-uikit | 1.63 → 1.67 | 4.33 → 4.46 | 60 → 63 |
| burst | transcriptkit-stream | 2.34 → 2.39 | 4.26 → 4.37 | 75 → 79 |
| rich-history | transcriptkit-stream | 2.25 → 2.31 | 5.51 → 5.63 | 92 → 97 |
| rich-burst | transcriptkit-uikit | 2.27 → 2.26 | 4.51 → 4.54 | 95 → 103 |
| scroll | transcriptkit-stream | 1.82 → 1.87 | 1.86 → 1.92 | 77 → 81 |
| rich-scroll | transcriptkit-stream | 1.73 → 1.80 | 1.92 → 1.98 | 97 → 103 |

(Scroll is compared with `../results-iphone12mini-2026-11-16/`, the last run that had it.)

- No dropped frames and no hitches in any of the 72 runs, as before; the worst frame is 16.8 ms everywhere.
- CPU is within 1 to 4 % of 16 November; the harness on its own (`none`) moved by up to 7 % between the two days,
  so this is within the noise.
- Peak memory is 3 to 8 MB (5 to 8 %) higher in every scenario, scrolling included: the tiles and the tail strip
  are 24 points wider than the view so that shapes can reach past the text, about 6.4 % more pixels at this width.

## Tests and timings on the phone

All 122 tests pass (release build). Layout per update: 19.4 µs for the benchmark answer, 32.6 µs for a paragraph
with a pill and a marker every few words, 22.4 µs for the same without shapes; parser timings as this morning.

## The chat sample's animation, traced (Release build, Animation Hitches with Points of Interest)

What tracing found, and what was changed:

1. **Masks cost two offscreen passes a frame.** Each band's reveal used a mask layer. Offscreen passes during an
   animation peaked at 13 against 11 around it. The band layers now clip their picture to their own bounds, which
   grow from the left; the peak during an animation is 11, the same as without one. A test checks that the
   animation's layers have no masks, shadows or sublayers.
2. **Starting an animation cost 1.3 ms in layer building alone** (Mac): every glyph got its own arrays of about
   50 numbers per curve, converted between Swift and Objective-C on assignment. Shared arrays, kept as Swift
   arrays, bring it to 0.46 ms on the phone. A whole start (recipe, drawing the glyphs' pictures, layers) now
   takes about 0.9 ms in the timing test, and 3 to 4 ms of the main thread in the app (cold).
3. **The animation's layers were committed on their own.** Adding and removing them in an explicit transaction,
   outside UIKit's, committed them separately from the tiles and tail that stop or start drawing the tag, so a
   frame could show the glyphs twice or not at all. They now go in the same commit; the layers take no implicit
   animations instead.
4. **A finished stream could still be taken for a new document.** If the view took the stream's last layout from
   the engine after switching to the finished document, it passed it over, and the document's layout, built on
   it, looked like a replacement: tags were drawn at rest (one launch in about eleven). The view now keeps a layout
   it passed over for that reason and installs it with the next one. Ten launches in a row afterwards: all
   appends.
5. **Waiting tags start on the next turn of the run loop**, not in the frame that let them play. In the sample
   that frame is also the one where the app adds what goes below a finished answer; it mostly still is the same
   display frame, so this helps less than hoped.

What remains:

- With the default timing, 9 of 20 launches had a one-frame render hitch at some point during the animation
  (shortly after it starts, about 1.4 s in, or on its last frame). Render times during animations are the same as
  around them (median 3 to 5 ms, slowest 9 to 15 ms, all under a frame) and the same with or without the explicit
  transaction (an A/B of six launches each). The animation makes Core Animation render every frame for 1.65 s
  (about 100 renders, against about 50 while text streams), so more frames can miss their deadline: about one in a
  hundred animated frames. Any animation of that length in the app would do the same.
- With `.afterStreamFinishes`, the animation starts in the frame where the sample shows its action bar and
  suggestion chips, which hitches by itself (an app update of about 45 ms) in about half the launches with or
  without an animation; TranscriptKit adds 3 to 4 ms to it.
- The sample's other hitches: its launch (220 to 330 ms), the moment the assistant's message first appears (one
  frame: SwiftUI builds the message views; TranscriptKit's part is the text view's setup, about 2 ms, and its first
  synchronous layout) and the end of the answer (above).
