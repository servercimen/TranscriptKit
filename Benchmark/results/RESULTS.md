# Streaming benchmark: simulator results

Run on 2026-11-15 in the iOS 27.0 simulator (iPhone 17) on an Apple M2 Pro. Textual 0.5.0.
Three launches per case; the tables show medians. Raw numbers are in `results.json`.

**These are simulator numbers.** The simulator runs on the Mac's CPU, so they show how the
renderers compare with each other, not how any of them performs on a phone.

**Every target is now built with optimisation.** Until 2026-11-15 the benchmark app was built with `-O`, but Xcode
compiled the Swift packages, TranscriptKit and Textual, with `-Onone`. WKWebView is system code and was always
optimised. `run.py` now passes the optimisation settings on the command line, which reaches the packages too. The
earlier, unoptimised numbers are kept in `results-unoptimised.json` and `tables-unoptimised.md`. They are not
comparable with the tables below.

## What was measured

The app streams the same Markdown into one renderer per launch.

- **Dropped frames, hitch ms/s, worst frame:** from a display link on the app's main thread.
  A dropped frame is a screen refresh during which the main thread was too busy to respond.
- **Main-thread CPU:** CPU seconds used by the main thread during the run (each run lasts about 21 s; burst about 11 s).
- **Process CPU:** CPU seconds used by all of the app's threads. TranscriptKit now parses and lays out on background
  queues, so main-thread CPU alone would hide that work.
- **Memory after:** the app's footprint after the run. **In use after:** the same, after asking malloc to return its
  free pages, as the system does under memory pressure. It is recorded for the TranscriptKit renderers and the
  baseline only; the Textual and WKWebView rows come from a run made before the column existed.
- **Memory peak:** the footprint's lifetime peak.
- **Page dropped frames:** for WKWebView only, the same frame count taken inside the page.

Scenarios update the view every 4 ms (about 250 times a second) except **realistic**, which updates every 33 ms (about
30 times a second), closer to how a network stream delivers text.

Renderers:

- **none:** streams the text into nothing. It measures the harness itself (the update loop and its timers), which every
  other row includes.
- **transcriptkit:** the whole conversation as one document in one view, given a new document through SwiftUI on every chunk.
  Layout runs on a background queue.
- **transcriptkit-stream:** the same view attached to a `TranscriptStream`. Once per frame the chunks are handed to a
  background queue that parses them and passes the document straight to the view's layout queue, which also draws the
  end of the document; the main thread installs the finished layout and that drawing together. SwiftUI re-measures the
  view only when its height changes.
- **transcriptkit-uikit:** the stream path in a UIScrollView with Auto Layout, with no SwiftUI in the update loop. A
  height change updates the scroll view's content size directly.
- **textual / textual-noselect:** one `StructuredText` per message in a `LazyVStack`, with and without text selection.
- **webview:** a WKWebView whose last message is replaced with new HTML on every chunk.

## Results

The TranscriptKit rows are from the final code of 2026-11-15 (parsing and layout off the main thread, the end of a
growing document drawn on the layout queue, at most one layout per display frame); the other rows are from earlier the
same day, with the same harness. **transcriptkit-uikit** is the stream path hosted in a UIScrollView instead of a
SwiftUI `ScrollView`. The **scroll** scenario scrolls through 50 earlier messages at 3000 points/s for 10 s.

### single: 6000 characters at 300/s, 0 earlier messages, an update every 4 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| none | 3/3 | 0 | 0.0 | 16.7 | 0.20 | 0.63 | 16 | 16 | 17 | – |
| transcriptkit | 3/3 | 0 | 0.0 | 16.7 | 2.58 | 3.90 | 37 | 37 | 49 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.7 | 1.39 | 2.89 | 37 | 37 | 49 | – |
| transcriptkit-uikit | 3/3 | 0 | 0.0 | 16.7 | 1.30 | 2.85 | 36 | 36 | 45 | – |
| textual | 3/3 | 10 | 7.3 | 65.2 | 13.19 | 13.60 | 71 | – | 96 | – |
| textual-noselect | 3/3 | 10 | 7.7 | 63.0 | 13.15 | 13.58 | 72 | – | 93 | – |
| webview | 3/3 | 0 | 0.0 | 16.7 | 2.39 | 3.18 | 26 | – | 27 | 0 |

### history: 6000 characters at 300/s, 50 earlier messages, an update every 4 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| none | 3/3 | 0 | 0.0 | 16.7 | 0.21 | 0.65 | 16 | 16 | 17 | – |
| transcriptkit | 3/3 | 0 | 0.0 | 16.7 | 2.63 | 3.91 | 40 | 40 | 55 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.7 | 1.39 | 2.86 | 40 | 40 | 55 | – |
| transcriptkit-uikit | 3/3 | 0 | 0.0 | 16.7 | 1.29 | 2.79 | 40 | 40 | 53 | – |
| textual | 3/3 | 22 | 17.0 | 155.6 | 14.55 | 14.78 | 159 | – | 196 | – |
| textual-noselect | 3/3 | 8 | 6.6 | 50.6 | 14.52 | 14.76 | 158 | – | 195 | – |
| webview | 3/3 | 0 | 0.0 | 16.7 | 2.30 | 3.05 | 31 | – | 31 | 0 |

### burst: 20000 characters at 2000/s, 0 earlier messages, an update every 4 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| none | 3/3 | 0 | 0.0 | 16.7 | 0.12 | 0.34 | 16 | 16 | 18 | – |
| transcriptkit | 3/3 | 0 | 0.0 | 16.7 | 1.22 | 1.97 | 36 | 36 | 55 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.7 | 0.97 | 1.72 | 36 | 36 | 54 | – |
| transcriptkit-uikit | 3/3 | 0 | 0.0 | 16.7 | 0.91 | 1.74 | 35 | 35 | 51 | – |
| textual | 3/3 | 303 | 457.2 | 126.9 | 9.34 | 9.62 | 180 | – | 248 | – |
| textual-noselect | 3/3 | 308 | 465.1 | 151.3 | 9.32 | 9.60 | 180 | – | 248 | – |
| webview | 3/3 | 0 | 0.0 | 16.7 | 1.48 | 1.76 | 57 | – | 57 | 1 |

### realistic: 6000 characters at 300/s, 50 earlier messages, an update every 33 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| none | 3/3 | 0 | 0.0 | 16.7 | 0.12 | 0.21 | 16 | 16 | 17 | – |
| transcriptkit | 3/3 | 0 | 0.0 | 16.7 | 1.61 | 2.38 | 44 | 44 | 55 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.7 | 1.11 | 1.91 | 43 | 43 | 54 | – |
| transcriptkit-uikit | 3/3 | 0 | 0.0 | 16.7 | 0.98 | 1.79 | 43 | 43 | 53 | – |
| textual | 3/3 | 36 | 28.6 | 160.6 | 7.00 | 7.12 | 159 | – | 195 | – |
| textual-noselect | 3/3 | 28 | 22.2 | 158.7 | 6.97 | 7.10 | 159 | – | 195 | – |
| webview | 3/3 | 0 | 0.0 | 16.7 | 1.41 | 1.78 | 21 | – | 21 | 0 |

### scroll: scrolling through 50 earlier messages at 3000 points/s for 10 s

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| transcriptkit | 3/3 | 0 | 0.0 | 16.7 | 1.18 | 1.21 | 52 | 52 | 76 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.7 | 1.16 | 1.19 | 53 | 53 | 76 | – |
| transcriptkit-uikit | 3/3 | 0 | 0.0 | 16.7 | 0.92 | 0.95 | 52 | 52 | 75 | – |

## What the numbers say

- **TranscriptKit dropped no frames.** WKWebView dropped none on the main thread and at most 1 inside the page. Textual
  dropped frames in every streaming scenario.
- **With the stream, TranscriptKit uses less main-thread CPU than WKWebView's app side:** 1.39 s against 2.39 s for a
  single answer, 1.39 s against 2.30 s with history, 0.97 s against 1.48 s in the burst and 1.11 s against 1.41 s at the
  realistic rate. WKWebView's rendering process is not counted, so this comparison still flatters WKWebView.
- **Counting all threads, TranscriptKit with the stream is level with WKWebView's app side:** 2.89 s against 3.18 s for a
  single answer, 1.72 s against 1.76 s in the burst, 1.91 s against 1.78 s at the realistic rate.
- **Conversation length does not matter to TranscriptKit's CPU:** 1.39 s for a single answer and after 50 messages.
- **Textual uses 6 to 11 times TranscriptKit's main-thread CPU.** Built with optimisation it drops far fewer frames than
  in the unoptimised runs (10 instead of 41 for a single answer), but still drops hundreds in the burst.
- **Memory:** TranscriptKit settles at 35 to 44 MB and peaks at 45 to 55 MB while streaming. Textual grows with content:
  71 MB after one answer, about 160 to 180 MB with history or after the burst.

## Drawing the growing end off the main thread

After parsing and layout moved off the main thread, most of what remained there was Core Animation redrawing the text
that had just changed. The end of a growing document is now drawn on the layout queue into IOSurfaces that the view
installs as a layer's contents; see `../results-iphone12mini/RESULTS.md` for the experiments behind this and the
comparison on a phone, where it saves 24 to 35% of main-thread CPU on the stream path for 6 to 8% more CPU in total.
In the simulator, against the optimised run of the code before the change (stream path):

| Scenario | Main-thread CPU before | After | Process CPU before | After |
|---|---|---|---|---|
| single | 1.73 s | 1.39 s (-20%) | 2.67 s | 2.89 s (+8%) |
| history | 1.71 s | 1.39 s (-19%) | 2.62 s | 2.86 s (+9%) |
| burst | 1.49 s | 0.97 s (-35%) | 1.95 s | 1.72 s (-12%) |
| realistic | 1.18 s | 1.11 s (-6%) | 1.56 s | 1.91 s (+22%) |

The simulator handles IOSurface contents less efficiently than a phone (a side experiment found swapping IOSurfaces
cost the simulator's main thread far more than the phone's), so these numbers understate the change.

## Moving parsing and layout off the main thread

Measured before the change above. The parser became incremental (each line is parsed once, and the open block's inline Markdown resumes from where the
last certain decision was made), finished blocks and their layouts stopped being copied on every update, and parsing and
layout moved to background queues. Old against new code, both built with optimisation, with the stream. The old code's
runs are in `results-before-offmain.json`.

| Scenario | Main-thread CPU before | After | Process CPU before | After | Memory after, before | After |
|---|---|---|---|---|---|---|
| single | 2.03 s | 1.73 s (-15%) | 2.45 s | 2.67 s (+9%) | 37 MB | 37 MB |
| history | 2.15 s | 1.71 s (-20%) | 2.56 s | 2.62 s (+2%) | 37 MB | 43 MB |
| burst | 1.61 s | 1.49 s (-7%) | 1.79 s | 1.95 s (+9%) | 35 MB | 35 MB |
| realistic | 1.48 s | 1.18 s (-20%) | 1.61 s | 1.56 s (-3%) | 37 MB | 43 MB |

Without the harness's own share (the **none** row), main-thread CPU fell 16% for a single answer, 23% with history,
8% in the burst and 22% at the realistic rate.

- **Main-thread CPU fell, but by a fifth, not more.** Parsing and layout were only part of the main thread's work. A
  12-second profile of the history scenario after the change: of the main thread's busy samples, about three quarters
  are Core Animation committing the frame (mostly backing-store updates, with drawing our text about a fifth of that),
  about 15% is SwiftUI re-measuring the view when its height changes, and about 5% is installing the new layout.
- **Total CPU did not fall.** At the 4 ms rate it rose by 2 to 9 percent (handing work between threads and checking each
  result against what is on screen cost more than the faster parser saves); at the realistic rate it fell 3 percent.
  The parser itself is much cheaper: in a release-build test it does 4.0 µs of work per append on this corpus against
  10.7 µs before, and 36 µs against 469 µs while a 3,900-character single-line paragraph streams in.
- **Memory after the run with 50 earlier messages rose from 37 to 43 MB**, and the peak from 48 to 55 MB. Malloc
  reports almost the same live data in both versions (13.8 MB against 13.5 MB). The difference is in how it is
  spread: the old code's small-allocation pages included 10 MB of completely free pages, which do not count towards
  the footprint, while in the new code only 4.8 MB of pages are completely free and more pages hold a mix of live
  objects and free space. Asking malloc to release free memory does not change it. My interpretation, not verified:
  layouts are now allocated on a background thread, and malloc's per-CPU caches leave long-lived and short-lived
  objects interleaved on more pages. It may look different on a phone, which has fewer cores.

## Owning the update loop

Measured before the change above, with TranscriptKit unoptimised. `TranscriptStream` replaced handing the
view a new document through SwiftUI for every chunk; main-thread CPU, medians of three runs:

| Scenario | Document through SwiftUI | `TranscriptStream` | Change |
|---|---|---|---|
| single | 3.83 s | 2.16 s | -44% |
| history | 4.23 s | 2.36 s | -44% |
| burst | 2.33 s | 1.60 s | -31% |
| realistic | 2.15 s | 1.68 s | -22% |

## Before and after the first optimisation pass

Measured with TranscriptKit unoptimised. The first run of this benchmark (kept in `results-before-fix.json` and
`tables-before-fix.md`) showed TranscriptKit's main-thread CPU growing with conversation length. Profiling pointed at
whole-document comparisons, redrawing three screens per chunk, rebuilding the layout index and copying the block list
on every update. After fixing those:

| Scenario | Main-thread CPU before | After | Peak memory before | After |
|---|---|---|---|---|
| single | 5.85 s | 4.66 s | 117 MB | 47 MB |
| history | 13.92 s | 4.92 s | 83 MB | 50 MB |
| burst | 3.56 s | 2.40 s | 84 MB | 57 MB |

## Limits of this benchmark

- **WKWebView is undercounted.** It lays out and draws in a separate process, so its CPU and memory there are not in these
  numbers. Only the app-side cost and the in-page frame pacing are.
- **The WKWebView case does not parse Markdown in JavaScript.** HTML is produced natively by TranscriptKit's parser. A page
  using a JavaScript Markdown library would do more work than this.
- **Updates are very frequent in most scenarios.** The app appends whatever is due every 4 ms, so at 300 characters/s most
  updates carry one or two characters. A network stream usually delivers fewer, larger chunks. This is harder on every
  renderer.
- **Frame drops are measured on the main thread only.** Work on the render server, and text that arrives a frame late
  because it was still being laid out in the background, are not seen.
- **The simulator schedules background queues on the Mac's cores.** On a phone they may run on efficiency cores, which
  could delay layouts; TranscriptKit's queues use the user-initiated quality of service to avoid that.
- **The corpus has no tables or images**, which TranscriptKit does not render yet.
- **The app uses the Debug configuration with optimisation settings** (`-O`, whole-module, no testability) for every target.
- **`-noTail 1`** makes TranscriptKit draw the growing end on the main thread as before, for comparisons.

## Running it

```bash
python3 Benchmark/run.py --device <simulator UDID> --build
```
