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
| none | 0/0 | – | – | – | – | – | – | – | – | – |
| transcriptkit | 3/3 | 0 | 0.0 | 16.8 | 1.79 | 1.83 | 48 | 48 | 76 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.8 | 1.78 | 1.83 | 49 | 49 | 76 | – |
| transcriptkit-uikit | 3/3 | 0 | 0.0 | 16.8 | 1.39 | 1.43 | 44 | 44 | 75 | – |
| textual | 0/0 | – | – | – | – | – | – | – | – | – |
| textual-noselect | 0/0 | – | – | – | – | – | – | – | – | – |
| webview | 0/0 | – | – | – | – | – | – | – | – | – |

