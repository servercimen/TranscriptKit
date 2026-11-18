### rich-history: 6000 characters at 300/s, 50 earlier messages, an update every 4 ms, rich text

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| transcriptkit-stream | 2/2 | 0 | 0.0 | 16.7 | 1.37 | 2.88 | 52 | 52 | 75 | – |
| transcriptkit-uikit | 2/2 | 0 | 0.0 | 16.7 | 1.37 | 2.98 | 52 | 52 | 71 | – |

### rich-burst: 20000 characters at 2000/s, 0 earlier messages, an update every 4 ms, rich text

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| transcriptkit-stream | 2/2 | 0 | 0.0 | 16.7 | 1.11 | 1.97 | 38 | 38 | 68 | – |
| transcriptkit-uikit | 2/2 | 0 | 0.0 | 16.7 | 1.03 | 1.93 | 38 | 38 | 61 | – |

