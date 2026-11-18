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

