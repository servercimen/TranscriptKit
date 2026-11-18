# After list numbering, all HTML entities, email links and reference links (simulator)

Same setup as `results-markdown-elements/NOTES.md`: iOS 27.0 simulator (iPhone 17), three launches per case, medians,
nothing else running. Compared with that run, which came before these four additions.

| Scenario | Renderer | Main-thread CPU s | Process CPU s | In use after MB |
|---|---|---|---|---|
| history | transcriptkit-stream | 1.35 → 1.36 | 2.88 → 2.88 | 40 → 43 |
| history | transcriptkit-uikit | 1.26 → 1.26 | 2.85 → 2.83 | 42 → 42 |
| burst | transcriptkit-stream | 1.03 → 1.00 | 1.85 → 1.81 | 36 → 39 |
| burst | transcriptkit-uikit | 0.91 → 0.92 | 1.81 → 1.81 | 35 → 35 |

CPU is unchanged within noise. Memory after the run is 3 MB higher for the stream renderer only, and unchanged for
the UIKit-hosted one, which runs the same parser; the benchmark text has no "&", "@" or reference links, so the new
tables are not loaded. Likely noise, but not shown to be.
