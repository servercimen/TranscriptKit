# iPhone 12 mini, 16 November 2026: after the Markdown additions

The library after everything added on 16 November (tables, task lists, nesting, strikethrough, images, HTML subset,
list numbering, all HTML entities, email links, reference links), measured on the iPhone 12 mini (iOS 27.0, 60 Hz,
not in Low Power Mode, thermal state nominal in all 99 runs). Every target built with optimisation, three launches per
case, medians. Full tables are in `tables.md`, raw numbers in `results.json`.

Compared with `../results-iphone12mini/` (15 November, same phone, same build settings), which came before any of
the additions.

## Control: the harness on its own

`none` streams into nothing. If the phone or the system had changed, it would show here.

| Scenario | Main-thread CPU s (15 Nov → 16 Nov) | Process CPU s |
|---|---|---|
| single | 0.36 → 0.41 | 0.90 → 1.11 |
| history | 0.40 → 0.39 | 1.08 → 1.05 |
| burst | 0.20 → 0.20 | 0.54 → 0.54 |
| realistic | 0.17 → 0.17 | 0.29 → 0.29 |

Unchanged except `single`, which is 0.05–0.2 s higher; read `single` with that in mind.

## The same text as before

The benchmark's original text (`Corpus.section`) has none of the new elements, so this is the cost of the new
parser and layout on ordinary answers.

| Scenario | Renderer | Main-thread CPU s | Process CPU s | Dropped frames |
|---|---|---|---|---|
| history | transcriptkit-stream | 1.89 → 1.84 | 4.59 → 4.68 (+2%) | 0 → 0 |
| history | transcriptkit-uikit | 1.64 → 1.60 | 4.31 → 4.49 (+4%) | 0 → 0 |
| history | transcriptkit (document) | 4.44 → 4.81 (+8%) | 6.91 → 7.25 (+5%) | 0 → 0 |
| burst | transcriptkit-stream | 2.34 → 2.37 | 4.26 → 4.40 (+3%) | 0 → 0 |
| burst | transcriptkit-uikit | 1.84 → 1.89 | 3.79 → 4.00 (+6%) | 0 → 0 |
| realistic | transcriptkit-stream | 1.41 → 1.38 | 2.55 → 2.66 (+4%) | 0 → 0 |
| realistic | transcriptkit-uikit | 1.13 → 1.12 | 2.24 → 2.37 (+6%) | 0 → 0 |
| scroll | transcriptkit-stream | 1.78 → 1.82 | 1.83 → 1.86 | 0 → 0 |
| scroll | transcriptkit-uikit | 1.39 → 1.43 | 1.43 → 1.46 | 0 → 0 |

- With a stream, where parsing and layout run off the main thread, main-thread CPU is unchanged and total CPU is
  2–6% higher.
- The `transcriptkit` row is the document path through SwiftUI, where the benchmark parses on the main thread; there
  the parser's extra cost shows on the main thread (+8% in history, +13% in single).
- Memory in use after a run is the same or lower, except `single` with `transcriptkit-uikit` (42 → 54 MB), which
  the other scenarios do not repeat.

## The new text

`-corpus rich` streams `Corpus.richSection`: per section a 10-line table with a row that widens a column, citations
whose definitions come at the end of the section, a task list with a nested numbered list, a nested quote,
strikethrough, an email address, a bare URL, entities, `<b>` and `<br>`, and an image (shown as its alt text). A
conversation of 50 messages holds 105 tables, 208 definitions and 210 references (counted by the app; see `content`
in `results.json`).

| Scenario | Renderer | Main-thread CPU s | Process CPU s | Dropped frames | In use after MB | Peak MB |
|---|---|---|---|---|---|---|
| rich-history | transcriptkit-stream | 2.27 | 5.64 | 0 | 62 | 92 |
| rich-history | transcriptkit-uikit | 2.04 | 5.42 | 0 | 49 | 89 |
| rich-history | transcriptkit (document) | 4.49 | 7.45 | 0 | 50 | 92 |
| rich-burst | transcriptkit-stream | 2.56 | 4.85 | 0 | 48 | 95 |
| rich-burst | transcriptkit-uikit | 2.20 | 4.54 | 0 | 48 | 94 |
| rich-scroll | transcriptkit-stream | 1.73 | 1.92 | 0 | 64 | 97 |
| rich-scroll | transcriptkit-uikit | 1.37 | 1.61 | 0 | 57 | 81 |

Against the original text in the same scenario, the new text costs 20–28% more main-thread CPU and about 20% more in
total while streaming into a conversation, 8–16% more main-thread CPU and 10–14% more in total in a burst, and the
same main-thread CPU when scrolling (3–10% more in total). Part
of that is simply more to draw: tiles were redrawn 230 times in `rich-history` against 70 with the original text.
In the simulator, leaving the definitions out drew about as many tiles, so it is probably mostly the tables, which
are drawn from their top again when a row widens a column. No run dropped a frame.

For context only, `webview` on `rich-history`: 2.55 s main-thread, 3.30 s in the app (its own rendering process is not
counted). It is not like for like: it parses with TranscriptKit on the main thread and renders through `HTML.render`,
which links no references and shows images as an empty character.

## Fixed before this run

The simulator check of the new text found two problems, fixed before measuring:

- **Dropped frames when a definition arrived.** A reference restyled by a late definition made the view redraw
  everything from that paragraph down to the bottom strip, tables included: 3–7 dropped frames per run in the
  simulator (worst frame 33–44 ms), and none with the definitions left out (`-noDefinitions 1`); see
  `../sim-defs-exp-0` (with) and `../sim-defs-exp-1` (without). Layouts now report
  restyled blocks as their own rectangles, and only those are redrawn: 0 dropped frames, worst frame 16.7 ms
  (`../sim-defs-exp-fix`).
- **Squeezed table columns.** A long cell took most of a table's width, so short columns wrapped mid-word. Columns
  now get at least their longest word, and only the space left is shared out.

## Profile

Time Profiler on the phone, `transcriptkit-stream` in `history` and in `rich-history` (traces in the session's
scratchpad, not kept). Both traces hold exactly 5,210 samples over 23 s, so they are compared by shares within a
trace, not by totals.

- The parse queue is about 7% of the app's samples in both. About 60% of it is spent building or searching strings
  in the block parser and the stream parser, and 30–35% in one place: the new `LineScanner`'s `rest` getter, which
  rebuilds the rest of the line from an array of characters several times per line, for the line still being written
  on every frame. Next come string operations directly in `BlockParser.State.process` (15–18%) and in splitting
  chunks into lines (7–9%). The inline parser is 13–15%. This is the clearest cost the additions brought, and likely
  most of the 2–6% above.
- The rest is distributed as before: drawing the bottom strip about 20%, layout about 8%, Core Animation commits about
  20%. The new text's shares are close to the original text's; no single table or reference function stands out
  (several are inlined into `BlockLayout.init` in an optimised build).

## Since

The parser's string work found above was fixed the same evening: see
`../results-iphone12mini-2026-11-16-parser/NOTES.md`. The parse queue now does about 40% of the work it did here.
