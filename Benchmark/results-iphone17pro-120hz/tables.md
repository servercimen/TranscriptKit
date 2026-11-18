### single: 6000 characters at 300/s, 0 earlier messages, an update every 4 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| transcriptkit | 0/0 | – | – | – | – | – | – | – | – | – |
| transcriptkit-stream | 0/0 | – | – | – | – | – | – | – | – | – |
| transcriptkit-uikit | 0/0 | – | – | – | – | – | – | – | – | – |
| textual | 0/0 | – | – | – | – | – | – | – | – | – |
| webview | 0/0 | – | – | – | – | – | – | – | – | – |

### history: 6000 characters at 300/s, 50 earlier messages, an update every 4 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| transcriptkit | 3/3 | 0 | 0.0 | 8.4 | 1.87 | 2.92 | 44 | 44 | 70 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 8.4 | 0.80 | 1.85 | 44 | 44 | 70 | – |
| transcriptkit-uikit | 3/3 | 0 | 0.0 | 8.4 | 0.75 | 1.90 | 44 | 44 | 69 | – |
| textual | 3/3 | 46 | 18.0 | 86.3 | 13.91 | 14.16 | 160 | 160 | 195 | – |
| webview | 3/3 | 0 | 0.0 | 8.4 | 2.54 | 3.40 | 22 | 22 | 22 | 1261 |

### burst: 20000 characters at 2000/s, 0 earlier messages, an update every 4 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| transcriptkit | 0/0 | – | – | – | – | – | – | – | – | – |
| transcriptkit-stream | 0/0 | – | – | – | – | – | – | – | – | – |
| transcriptkit-uikit | 0/0 | – | – | – | – | – | – | – | – | – |
| textual | 0/0 | – | – | – | – | – | – | – | – | – |
| webview | 0/0 | – | – | – | – | – | – | – | – | – |

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

