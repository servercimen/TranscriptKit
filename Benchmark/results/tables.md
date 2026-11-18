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
| none | 0/0 | – | – | – | – | – | – | – | – | – |
| transcriptkit | 3/3 | 0 | 0.0 | 16.7 | 1.18 | 1.21 | 52 | 52 | 76 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.7 | 1.16 | 1.19 | 53 | 53 | 76 | – |
| transcriptkit-uikit | 3/3 | 0 | 0.0 | 16.7 | 0.92 | 0.95 | 52 | 52 | 75 | – |
| textual | 0/0 | – | – | – | – | – | – | – | – | – |
| textual-noselect | 0/0 | – | – | – | – | – | – | – | – | – |
| webview | 0/0 | – | – | – | – | – | – | – | – | – |

