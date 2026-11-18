# Streaming benchmark on an iPhone 17 Pro

Run on 2026-11-15 on an iPhone 17 Pro (120 Hz ProMotion, iOS 27.0.1), launched with `devicectl`. Textual 0.5.0.
Three launches per case; the tables show medians. Raw numbers are in `results.json` here and in
`../results-iphone17pro-120hz/`. The method and the meaning of each column are described in `../results/RESULTS.md`;
every target is built with optimisation. The phone's thermal state was "fair" (slightly warm) for the 120 Hz runs and
was not recorded for the 60 Hz ones.

An iPhone app runs at 60 Hz unless its Info.plist opts in to ProMotion with `CADisableMinimumFrameDurationOnPhone`.
The benchmark app was measured both ways: without the key (60 Hz, comparable with the iPhone 12 mini) and with it
(`run.py --promotion`, 120 Hz). With the key, the frame monitor and the scroller ask for 120 Hz; TranscriptKit still
updates streamed text at most 60 times a second (see below), so the screen runs at 120 Hz with text changing every
other frame.

## 60 Hz

The TranscriptKit document path (**transcriptkit**) rows were measured after the frame-rate fix described below; the
other rows before it, which does not affect them at 60 Hz.

### single: 6000 characters at 300/s, 0 earlier messages, an update every 4 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| none | 3/3 | 0 | 0.0 | 16.8 | 0.18 | 0.49 | 12 | 12 | 13 | – |
| transcriptkit | 3/3 | 0 | 0.0 | 16.7 | 1.86 | 3.11 | 41 | 41 | 69 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.7 | 0.93 | 2.26 | 41 | 41 | 69 | – |
| transcriptkit-uikit | 3/3 | 0 | 0.0 | 16.7 | 0.79 | 2.06 | 40 | 40 | 65 | – |
| textual | 3/3 | 4 | 2.8 | 76.5 | 12.89 | 13.20 | 71 | 71 | 91 | – |
| textual-noselect | 3/3 | 4 | 3.0 | 79.4 | 12.86 | 13.17 | 70 | 70 | 91 | – |
| webview | 3/3 | 0 | 0.0 | 16.7 | 2.57 | 3.36 | 23 | 23 | 23 | 0 |

### history: 6000 characters at 300/s, 50 earlier messages, an update every 4 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| none | 3/3 | 0 | 0.0 | 16.8 | 0.18 | 0.49 | 12 | 12 | 13 | – |
| transcriptkit | 3/3 | 0 | 0.0 | 20.8 | 1.80 | 3.03 | 48 | 48 | 73 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.7 | 0.91 | 2.15 | 45 | 45 | 73 | – |
| transcriptkit-uikit | 3/3 | 0 | 0.0 | 16.7 | 0.79 | 2.03 | 44 | 44 | 72 | – |
| textual | 3/3 | 5 | 3.9 | 98.7 | 13.71 | 13.99 | 166 | 166 | 193 | – |
| textual-noselect | 3/3 | 6 | 4.4 | 98.1 | 13.69 | 13.98 | 164 | 164 | 193 | – |
| webview | 3/3 | 0 | 0.0 | 16.7 | 2.46 | 3.24 | 25 | 25 | 25 | 0 |

### burst: 20000 characters at 2000/s, 0 earlier messages, an update every 4 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| none | 3/3 | 0 | 0.0 | 16.7 | 0.10 | 0.25 | 12 | 12 | 13 | – |
| transcriptkit | 3/3 | 0 | 0.0 | 20.8 | 1.64 | 2.67 | 41 | 41 | 78 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.7 | 1.24 | 2.46 | 39 | 39 | 78 | – |
| transcriptkit-uikit | 3/3 | 0 | 0.0 | 16.7 | 0.97 | 2.22 | 39 | 39 | 75 | – |
| textual | 3/3 | 115 | 168.2 | 83.7 | 8.55 | 8.66 | 191 | 191 | 259 | – |
| textual-noselect | 3/3 | 121 | 184.0 | 87.1 | 8.55 | 8.66 | 188 | 188 | 256 | – |
| webview | 3/3 | 0 | 0.0 | 16.7 | 1.28 | 1.61 | 58 | 58 | 58 | 0 |

### realistic: 6000 characters at 300/s, 50 earlier messages, an update every 33 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| none | 3/3 | 0 | 0.0 | 16.7 | 0.09 | 0.14 | 12 | 12 | 13 | – |
| transcriptkit | 3/3 | 1 | 0.0 | 25.0 | 0.87 | 1.43 | 52 | 52 | 71 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.7 | 0.66 | 1.25 | 52 | 52 | 70 | – |
| transcriptkit-uikit | 3/3 | 0 | 0.0 | 16.7 | 0.54 | 1.11 | 51 | 51 | 69 | – |
| textual | 3/3 | 8 | 6.1 | 130.0 | 8.08 | 8.19 | 158 | 158 | 193 | – |
| textual-noselect | 3/3 | 11 | 8.8 | 123.5 | 8.12 | 8.23 | 157 | 157 | 193 | – |
| webview | 3/3 | 0 | 0.0 | 16.7 | 1.35 | 1.83 | 14 | 14 | 15 | 0 |

### scroll: scrolling through 50 earlier messages at 3000 points/s for 10 s

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| none | 3/3 | 0 | 0.0 | 16.7 | 0.00 | 0.00 | 12 | 12 | 13 | – |
| transcriptkit | 3/3 | 0 | 0.0 | 16.7 | 0.91 | 0.93 | 63 | 63 | 89 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.7 | 0.93 | 0.95 | 56 | 56 | 89 | – |
| transcriptkit-uikit | 3/3 | 0 | 0.0 | 16.7 | 0.80 | 0.81 | 53 | 53 | 72 | – |
| textual | 3/3 | 60 | 88.4 | 120.5 | 4.05 | 4.10 | 128 | 128 | 200 | – |
| textual-noselect | 3/3 | 54 | 77.9 | 93.1 | 4.04 | 4.09 | 127 | 127 | 193 | – |
| webview | 3/3 | 0 | 0.0 | 16.7 | 0.44 | 0.64 | 12 | 12 | 15 | 0 |

## 120 Hz (app opted in to ProMotion)

Dropped frames here are counted against 8.3 ms frames.

### history: 6000 characters at 300/s, 50 earlier messages, an update every 4 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| transcriptkit | 3/3 | 0 | 0.0 | 8.4 | 1.87 | 2.92 | 44 | 44 | 70 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 8.4 | 0.80 | 1.85 | 44 | 44 | 70 | – |
| transcriptkit-uikit | 3/3 | 0 | 0.0 | 8.4 | 0.75 | 1.90 | 44 | 44 | 69 | – |
| textual | 3/3 | 46 | 18.0 | 86.3 | 13.91 | 14.16 | 160 | 160 | 195 | – |
| webview | 3/3 | 0 | 0.0 | 8.4 | 2.54 | 3.40 | 22 | 22 | 22 | 1261 |

### realistic: 6000 characters at 300/s, 50 earlier messages, an update every 33 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| transcriptkit | 3/3 | 0 | 0.0 | 8.4 | 1.01 | 1.59 | 52 | 52 | 70 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 8.4 | 0.71 | 1.33 | 52 | 52 | 70 | – |
| transcriptkit-uikit | 3/3 | 0 | 0.0 | 8.4 | 0.58 | 1.18 | 51 | 51 | 69 | – |
| textual | 3/3 | 196 | 77.0 | 124.5 | 7.88 | 7.99 | 157 | 157 | 192 | – |
| webview | 3/3 | 0 | 0.0 | 8.4 | 1.40 | 1.88 | 14 | 14 | 14 | 1268 |

### scroll: scrolling through 50 earlier messages at 3000 points/s for 10 s

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| transcriptkit | 3/3 | 0 | 0.0 | 8.4 | 1.30 | 1.33 | 56 | 56 | 85 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 8.4 | 1.25 | 1.28 | 57 | 57 | 85 | – |
| transcriptkit-uikit | 3/3 | 0 | 0.0 | 8.4 | 0.97 | 1.00 | 54 | 54 | 89 | – |
| textual | 3/3 | 201 | 147.4 | 176.4 | 4.61 | 4.67 | 117 | 117 | 192 | – |
| webview | 3/3 | 0 | 0.0 | 8.4 | 0.64 | 0.87 | 12 | 12 | 15 | 694 |

## What the numbers say

- **TranscriptKit dropped no frames on this phone, at 60 or 120 Hz,** in any scenario; at 120 Hz its worst frame was
  8.4 ms. Textual dropped frames everywhere: 115 in the burst at 60 Hz, and at 120 Hz 46 with history, 196 at the
  realistic rate and 201 while scrolling.
- **With the stream, TranscriptKit's main thread does less than half of WKWebView's app side** with history (0.91 s
  against 2.46 s) and at the realistic rate (0.66 s against 1.35 s), and about the same in the burst (1.24 s against
  1.28 s), at 60 Hz.
  Counting all of TranscriptKit's threads (2.15 s), it is below WKWebView's app side alone (3.24 s), which still leaves
  out WebKit's own rendering process.
- **Hosted in a UIScrollView instead of SwiftUI,** 0.79 s with history and 0.54 s at the realistic rate.
- **Scrolling** through 50 messages costs TranscriptKit 0.93 s of main-thread CPU at 60 Hz and 1.25 s at 120 Hz (0.80 s
  and 0.97 s in a UIScrollView): twice the frames for about a third more work. WKWebView's app side uses 0.44 s and
  0.64 s.
- **Against the iPhone 12 mini,** the same TranscriptKit stream work takes about half the main-thread time (0.91 s
  against 1.89 s with history).

## The tail drawn off the main thread, on this phone

Same build at 60 Hz, with the end of a growing document drawn on the main thread (`-noTail 1`) and off it (the
default). Raw numbers in `../experiments-device/17pro-notail/`.

| Renderer, scenario | Main-thread CPU, tail on main | Off main | Process CPU, on main | Off main | Peak memory |
|---|---|---|---|---|---|
| stream (SwiftUI), history | 1.42 s | 0.91 s (-36%) | 2.09 s | 2.15 s (+3%) | 78 → 73 MB |
| stream (SwiftUI), realistic | 0.91 s | 0.66 s (-28%) | 1.17 s | 1.25 s (+7%) | 64 → 70 MB |
| stream (UIKit host), history | 1.29 s | 0.79 s (-39%) | 1.95 s | 2.03 s (+4%) | 77 → 72 MB |
| stream (UIKit host), realistic | 0.81 s | 0.54 s (-33%) | 1.05 s | 1.11 s (+7%) | 65 → 69 MB |
| document path, history | 2.44 s | 1.80 s (-26%) | 3.07 s | 3.03 s (-2%) | 77 → 73 MB |
| document path, realistic | 1.17 s | 0.87 s (-26%) | 1.38 s | 1.43 s (+3%) | 65 → 71 MB |

- **The main thread does 26 to 39% less work while text streams,** for 2% less to 7% more CPU in total.

## Frame-rate fixes this phone found

- **The layout engine's cap followed the screen, not the app.** The engine lays out at most once per display frame,
  and took the frame rate from `UIScreen.maximumFramesPerSecond`: 120 on this phone, although an app that has not
  opted in to ProMotion only draws at 60. When documents arrived through SwiftUI faster than that, the engine made
  twice as many layouts and tails as could be shown, and the document path used 35% more CPU in total with the tail
  than without. Fixed; the document path is now at 2% less CPU in total with the tail than without (history), and 26%
  less on the main thread.
- **Streamed text is updated at most 60 times a second,** on every screen. `TranscriptStream`'s display link asks for
  exactly 60 Hz, and the engine caps layouts at 60 per second. Updating text at 120 Hz would show nothing new and double
  the per-frame work; scrolling still runs at the screen's full rate. (With the earlier range of 30 to 60 Hz, the
  system ran the stream at 20 to 30 updates a second on this phone.)

## Limits

The limits listed in `../results/RESULTS.md` apply here too. In addition:

- The 120 Hz pass covers the history, realistic and scroll scenarios only, and has no tail-on-main comparison; at
  120 Hz text updates are capped at 60 per second, so the 60 Hz comparison applies.
- ProMotion lowers the screen's rate when nothing on it changes at 120 Hz. The frame monitor counts drops against
  8.3 ms frames, which is meaningful while something animates at 120 Hz (as in these runs) but would overcount when
  the screen settles at 60 Hz.
