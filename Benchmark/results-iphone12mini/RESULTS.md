# Streaming benchmark on an iPhone 12 mini

Run on 2026-11-15 on an iPhone 12 mini (A14, 60 Hz, iOS 27.0), launched with `devicectl`. Textual 0.5.0.
Three launches per case; the tables show medians. Raw numbers are in `results.json`. The method and the
meaning of each column are described in `../results/RESULTS.md`.

Every target, including the Swift packages, is built with optimisation. The earlier device runs compiled
TranscriptKit and Textual without it, so their CPU figures were too high and the comparison with WKWebView
(system code, always optimised) was skewed. Those runs are kept in `results-unoptimised.json`,
`tables-unoptimised.md` and `results-before-device-profile.json`, and are not comparable with the tables below.

The TranscriptKit rows are from the final code of 2026-11-15: parsing and layout off the main thread, the end of a
growing document drawn on the layout queue, and at most one layout per display frame. The Textual and WKWebView rows
are from an earlier run the same day, with the same harness. **transcriptkit-uikit** is the stream path hosted in a
UIScrollView with Auto Layout instead of a SwiftUI `ScrollView` (see `../TranscriptBench/Renderers.swift`). The
**scroll** scenario scrolls through the 50 earlier messages at 3000 points/s for 10 s without streaming.

## Results

### single: 6000 characters at 300/s, 0 earlier messages, an update every 4 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| none | 3/3 | 2 | 1.3 | 31.4 | 0.36 | 0.90 | 11 | 11 | 11 | – |
| transcriptkit | 3/3 | 0 | 0.0 | 16.8 | 4.36 | 6.91 | 43 | 43 | 59 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.8 | 1.85 | 4.61 | 43 | 43 | 59 | – |
| transcriptkit-uikit | 3/3 | 0 | 0.0 | 16.8 | 1.64 | 4.37 | 42 | 42 | 58 | – |
| textual | 3/3 | 14 | 11.0 | 103.4 | 14.91 | 15.22 | 65 | 65 | 101 | – |
| textual-noselect | 3/3 | 10 | 7.7 | 65.8 | 14.94 | 15.25 | 64 | 64 | 97 | – |
| webview | 3/3 | 0 | 0.0 | 16.8 | 2.51 | 3.35 | 25 | 25 | 25 | 2 |

### history: 6000 characters at 300/s, 50 earlier messages, an update every 4 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| none | 3/3 | 0 | 0.0 | 16.7 | 0.40 | 1.08 | 10 | 10 | 11 | – |
| transcriptkit | 3/3 | 0 | 0.0 | 16.8 | 4.44 | 6.91 | 41 | 41 | 64 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.8 | 1.89 | 4.59 | 41 | 41 | 63 | – |
| transcriptkit-uikit | 3/3 | 0 | 0.0 | 16.8 | 1.64 | 4.31 | 41 | 41 | 60 | – |
| textual | 3/3 | 248 | 180.9 | 65.4 | 20.03 | 20.14 | 150 | 150 | 152 | – |
| textual-noselect | 3/3 | 239 | 170.4 | 53.0 | 20.04 | 20.14 | 150 | 150 | 152 | – |
| webview | 3/3 | 0 | 0.0 | 16.8 | 2.56 | 3.40 | 25 | 25 | 25 | 0 |

### burst: 20000 characters at 2000/s, 0 earlier messages, an update every 4 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| none | 3/3 | 0 | 0.0 | 16.6 | 0.20 | 0.54 | 11 | 11 | 12 | – |
| transcriptkit | 3/3 | 0 | 0.0 | 16.8 | 3.39 | 5.11 | 36 | 36 | 75 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.8 | 2.34 | 4.26 | 37 | 37 | 75 | – |
| transcriptkit-uikit | 3/3 | 0 | 0.0 | 16.8 | 1.84 | 3.79 | 35 | 35 | 67 | – |
| textual | 3/3 | 271 | 405.9 | 138.4 | 9.55 | 9.67 | 168 | 168 | 236 | – |
| textual-noselect | 3/3 | 284 | 418.7 | 134.9 | 9.59 | 9.70 | 167 | 167 | 237 | – |
| webview | 3/3 | 0 | 0.0 | 16.8 | 1.61 | 1.97 | 51 | 51 | 51 | 0 |

### realistic: 6000 characters at 300/s, 50 earlier messages, an update every 33 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| none | 3/3 | 0 | 0.0 | 16.7 | 0.17 | 0.29 | 10 | 10 | 11 | – |
| transcriptkit | 3/3 | 0 | 0.0 | 16.8 | 1.99 | 3.04 | 48 | 48 | 61 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.8 | 1.41 | 2.55 | 48 | 48 | 61 | – |
| transcriptkit-uikit | 3/3 | 0 | 0.0 | 16.8 | 1.13 | 2.24 | 46 | 46 | 56 | – |
| textual | 3/3 | 39 | 25.6 | 70.0 | 12.02 | 12.11 | 150 | 150 | 153 | – |
| textual-noselect | 3/3 | 43 | 28.0 | 71.9 | 12.07 | 12.15 | 150 | 150 | 152 | – |
| webview | 3/3 | 0 | 0.0 | 16.8 | 2.12 | 2.83 | 13 | 13 | 13 | 17 |

### scroll: scrolling through 50 earlier messages at 3000 points/s for 10 s

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| transcriptkit | 3/3 | 0 | 0.0 | 16.8 | 1.79 | 1.83 | 48 | 48 | 76 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.8 | 1.78 | 1.83 | 49 | 49 | 76 | – |
| transcriptkit-uikit | 3/3 | 0 | 0.0 | 16.8 | 1.39 | 1.43 | 44 | 44 | 75 | – |

## What the numbers say

- **TranscriptKit dropped no frames in any run.** WKWebView dropped none on the app's main thread; inside the page it
  dropped 2 for a single answer and 17 at the realistic rate.
- **Textual cannot keep up with a long conversation on this phone:** 248 dropped frames per run with 50 earlier messages
  at the 4 ms rate, 271 in the burst, and about 40 at the realistic rate, with the main thread busy for 20 of the 21
  seconds in the history scenario.
- **TranscriptKit with the stream now uses less main-thread CPU than WKWebView's app side at the 4 ms rate:** 1.85 s
  against 2.51 s for a single answer, 1.89 s against 2.56 s with history, and 1.41 s against 2.12 s at the realistic
  rate. In the burst it is still higher (2.34 s against 1.61 s). Hosted in a UIScrollView instead of SwiftUI, it uses
  1.64 s, 1.64 s, 1.13 s and 1.84 s. WKWebView lays out and draws in its own process, which is not counted; counting
  all of TranscriptKit's threads (3.8 to 4.6 s at the 4 ms rate) against WKWebView's app side alone (2.0 to 3.4 s) is
  not a like-for-like comparison either.
- **Conversation length does not matter to TranscriptKit:** 1.85 s for a single answer, 1.89 s after 50 messages.
- **Textual uses 4 to 11 times TranscriptKit's main-thread CPU** with the stream.
- **Scrolling** through 50 messages costs TranscriptKit 1.78 s of main-thread CPU (1.39 s in a UIScrollView), with no
  dropped frames. In an earlier run the same day, WKWebView's app side used 0.89 s and Textual 4.46 s with 14 dropped
  frames (worst 143 ms).
- **Memory:** TranscriptKit ends at 35 to 48 MB and peaks at up to 75 MB in the burst. Textual ends at 64 MB after one
  answer and 150 to 168 MB with history or after the burst. WKWebView's app side stays at 13 to 51 MB.

## Drawing the growing end off the main thread

Experiments on this phone (2026-11-15, raw data in `../experiments/` and `../experiments-device/`) showed that after
parsing and layout had moved off the main thread, about 60% of what remained there was redrawing the text that had
just changed, and that this cost was per redraw, not per pixel: tiles a quarter of the size, or drawing fewer lines,
changed nothing. Handing Core Animation new pixels from a background thread through `CALayer.contents` was cheap on
the phone with IOSurfaces (but not with fresh `CGImage`s), and presenting through a `CAMetalLayer` from the background
saved more main-thread time but cost about 30% more CPU in total.

So the end of a growing document (the bottom 256 points) is now drawn on the layout queue into one of a few
IOSurfaces and installed as a layer's contents in the same transaction as the layout; the tiles draw only above it. A
second after the last update, the tiles take that part back. The engine also makes at most one layout per display
frame, which keeps a fast stream of documents set through SwiftUI from making several layouts (and tails) a frame.

Same build, with the tail drawn on the main thread (`-noTail 1`) and off it. Raw numbers in
`../experiments-device/final-notail/` and `results.json`:

| Renderer, scenario | Main-thread CPU, tail on main | Off main | Process CPU, on main | Off main | Tile redraws | Peak memory |
|---|---|---|---|---|---|---|
| stream (SwiftUI), history | 2.78 s | 1.89 s (-32%) | 4.34 s | 4.59 s (+6%) | 1,244 → 71 | 55 → 63 MB |
| stream (SwiftUI), realistic | 1.86 s | 1.41 s (-24%) | 2.40 s | 2.55 s (+6%) | 634 → 73 | 48 → 61 MB |
| stream (UIKit host), history | 2.51 s | 1.64 s (-35%) | 4.02 s | 4.31 s (+7%) | 1,235 → 61 | 52 → 60 MB |
| stream (UIKit host), realistic | 1.56 s | 1.13 s (-28%) | 2.08 s | 2.24 s (+8%) | 629 → 63 | 46 → 56 MB |
| document path, history | 5.12 s | 4.44 s (-13%) | 6.49 s | 6.91 s (+7%) | 1,252 → 71 | 55 → 64 MB |
| document path, realistic | 2.41 s | 1.99 s (-18%) | 2.88 s | 3.04 s (+6%) | 636 → 73 | 49 → 61 MB |

- **The main thread does a quarter to a third less work while text streams**, for 6 to 8% more CPU in total and 8 to
  13 MB more peak memory (the surfaces). Memory after the run is the same or lower: tiles that are not redrawn every
  frame do not keep a second backing buffer.
- **Before the per-frame cap,** the document path at the 4 ms rate made about 3,400 layouts in 20 s, and drawing a tail
  for each cost 47% more CPU in total. The cap brought it to one per frame; on its own it also lowered the document
  path's CPU (5.41 s to 5.12 s on the main thread, 7.24 s to 6.49 s in total, tail on main).

Over the whole day, the stream path with 50 earlier messages went from 3.53 s of main-thread CPU (optimised build of
the code as it was in the morning) to 2.81 s (parsing and layout off the main thread) to 1.89 s now, or 1.64 s
hosted in a UIScrollView: 46 to 54% less.

## Moving parsing and layout off the main thread

Measured before the change above. The parser became incremental, finished blocks and their layouts stopped being
copied on every update, and parsing and layout moved to background queues. Old against new code on this phone, both
built with optimisation, with the stream. The old code's runs are in `results-before-offmain.json`.

| Scenario | Main-thread CPU before | After | Process CPU before | After | Memory after, before | After |
|---|---|---|---|---|---|---|
| single | 3.36 s | 2.86 s (-15%) | 4.20 s | 4.36 s (+4%) | 55 MB | 55 MB |
| history | 3.53 s | 2.81 s (-20%) | 4.35 s | 4.26 s (-2%) | 46 MB | 52 MB |
| burst | 3.53 s | 3.16 s (-10%) | 3.92 s | 4.09 s (+4%) | 34 MB | 35 MB |
| realistic | 2.27 s | 1.85 s (-19%) | 2.62 s | 2.39 s (-9%) | 39 MB | 45 MB |

## Profiling on the device, 2026-11-14

Before both changes, with TranscriptKit unoptimised, a Time Profiler trace of the history scenario on this phone led to
three fixes: typesetting only from the last line of a growing block (1,817 samples to 730), redrawing fewer tiles
(1,512 to 1,128) and caching fonts (734 to not visible). What it then showed as remaining, the parser re-reading the
open block on each update (about 15 percent) and carrying the list of finished blocks' layouts into each new layout
(about 8 percent), is what the first change of 2026-11-15 addressed.

## Limits

The limits listed in `../results/RESULTS.md` apply here too. In addition:

- The phone's thermal state was not controlled or recorded.
- The **none** row dropped 2 frames in one single-answer run, so a frame or two can be lost to the system on this phone
  whatever the renderer does.
- The phone runs at 60 Hz. TranscriptKit updates streamed text at most 60 times a second on any screen; for 120 Hz
  results see `../results-iphone17pro/RESULTS.md`.
- A Time Profiler trace from the phone could not be symbolicated, so the split of the remaining main-thread time comes
  from the simulator.
