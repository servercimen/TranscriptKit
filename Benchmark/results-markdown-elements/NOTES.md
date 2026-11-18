# After adding the missing Markdown elements (simulator)

Run on 2026-11-16 in the iOS 27.0 simulator (iPhone 17) on the same Mac, three launches per case, medians.
Only the stream path, in the two scenarios that stress parsing most. Compared with `results/tables.md` (2026-11-15).

| Scenario | Renderer | Main-thread CPU s (before → after) | Process CPU s (before → after) | Dropped frames |
|---|---|---|---|---|
| history | transcriptkit-stream | 1.39 → 1.35 | 2.86 → 2.88 | 0 → 0 |
| history | transcriptkit-uikit | 1.29 → 1.26 | 2.79 → 2.85 | 0 → 0 |
| burst | transcriptkit-stream | 0.97 → 1.03 | 1.72 → 1.85 | 0 → 0 |
| burst | transcriptkit-uikit | 0.91 → 0.91 | 1.74 → 1.81 | 0 → 0 |

The main thread is unchanged within noise. Process CPU is up 1–2 % in the history scenario and 4–8 % in burst
(20,000 characters at 2,000/s), where parsing is the largest share of the work: the block parser now tracks nested
containers and the inline parser checks for bare URLs, entities and HTML tags. The benchmark text contains none of
the new elements, so this is the cost of looking for them.
