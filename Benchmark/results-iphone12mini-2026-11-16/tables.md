### single: 6000 characters at 300/s, 0 earlier messages, an update every 4 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| none | 3/3 | 1 | 0.7 | 31.5 | 0.41 | 1.11 | 10 | 10 | 11 | – |
| transcriptkit | 3/3 | 0 | 0.0 | 16.8 | 4.95 | 7.49 | 43 | 43 | 61 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.8 | 1.86 | 4.80 | 43 | 43 | 61 | – |
| transcriptkit-uikit | 3/3 | 0 | 0.0 | 16.8 | 1.62 | 4.52 | 54 | 54 | 57 | – |
| webview | 0/0 | – | – | – | – | – | – | – | – | – |

### history: 6000 characters at 300/s, 50 earlier messages, an update every 4 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| none | 3/3 | 0 | 0.0 | 16.7 | 0.39 | 1.05 | 10 | 10 | 11 | – |
| transcriptkit | 3/3 | 0 | 0.0 | 16.8 | 4.81 | 7.25 | 36 | 36 | 63 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.8 | 1.84 | 4.68 | 36 | 36 | 63 | – |
| transcriptkit-uikit | 3/3 | 0 | 0.0 | 16.8 | 1.60 | 4.49 | 35 | 35 | 60 | – |
| webview | 0/0 | – | – | – | – | – | – | – | – | – |

### burst: 20000 characters at 2000/s, 0 earlier messages, an update every 4 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| none | 3/3 | 0 | 0.0 | 16.7 | 0.20 | 0.54 | 10 | 10 | 11 | – |
| transcriptkit | 3/3 | 0 | 0.0 | 16.8 | 3.58 | 5.29 | 35 | 35 | 75 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.8 | 2.37 | 4.40 | 36 | 36 | 74 | – |
| transcriptkit-uikit | 3/3 | 0 | 0.0 | 16.8 | 1.89 | 4.00 | 39 | 39 | 68 | – |
| webview | 0/0 | – | – | – | – | – | – | – | – | – |

### realistic: 6000 characters at 300/s, 50 earlier messages, an update every 33 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| none | 3/3 | 0 | 0.0 | 16.7 | 0.17 | 0.29 | 10 | 10 | 11 | – |
| transcriptkit | 3/3 | 0 | 0.0 | 16.8 | 2.06 | 3.13 | 43 | 43 | 60 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.8 | 1.38 | 2.66 | 43 | 43 | 60 | – |
| transcriptkit-uikit | 3/3 | 0 | 0.0 | 16.8 | 1.12 | 2.37 | 39 | 39 | 57 | – |
| webview | 0/0 | – | – | – | – | – | – | – | – | – |

### scroll: scrolling through 50 earlier messages at 3000 points/s for 10 s

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| none | 3/3 | 0 | 0.0 | 16.7 | 0.01 | 0.01 | 10 | 10 | 11 | – |
| transcriptkit | 3/3 | 0 | 0.0 | 16.8 | 1.85 | 1.90 | 49 | 49 | 77 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.8 | 1.82 | 1.86 | 49 | 49 | 77 | – |
| transcriptkit-uikit | 3/3 | 0 | 0.0 | 16.8 | 1.43 | 1.46 | 45 | 45 | 75 | – |
| webview | 0/0 | – | – | – | – | – | – | – | – | – |

### rich-history: 6000 characters at 300/s, 50 earlier messages, an update every 4 ms, rich text

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| none | 3/3 | 0 | 0.0 | 16.7 | 0.35 | 1.00 | 10 | 10 | 11 | – |
| transcriptkit | 3/3 | 0 | 0.0 | 16.8 | 4.49 | 7.45 | 50 | 50 | 92 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.8 | 2.27 | 5.64 | 62 | 62 | 92 | – |
| transcriptkit-uikit | 3/3 | 0 | 0.0 | 16.8 | 2.04 | 5.42 | 49 | 49 | 89 | – |
| webview | 3/3 | 0 | 0.0 | 16.8 | 2.55 | 3.30 | 24 | 24 | 24 | 0 |

### rich-burst: 20000 characters at 2000/s, 0 earlier messages, an update every 4 ms, rich text

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| none | 3/3 | 0 | 0.0 | 16.7 | 0.20 | 0.53 | 10 | 10 | 11 | – |
| transcriptkit | 3/3 | 0 | 0.0 | 16.8 | 3.39 | 5.33 | 66 | 66 | 93 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.8 | 2.56 | 4.85 | 48 | 48 | 95 | – |
| transcriptkit-uikit | 3/3 | 0 | 0.0 | 16.8 | 2.20 | 4.54 | 48 | 48 | 94 | – |
| webview | 0/0 | – | – | – | – | – | – | – | – | – |

### rich-scroll: scrolling through 50 earlier messages at 3000 points/s for 10 s, rich text

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| none | 3/3 | 0 | 0.0 | 16.7 | 0.01 | 0.01 | 10 | 10 | 11 | – |
| transcriptkit | 3/3 | 0 | 0.0 | 16.8 | 1.76 | 1.94 | 62 | 62 | 98 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.8 | 1.73 | 1.92 | 64 | 64 | 97 | – |
| transcriptkit-uikit | 3/3 | 0 | 0.0 | 16.8 | 1.37 | 1.61 | 57 | 57 | 81 | – |
| webview | 0/0 | – | – | – | – | – | – | – | – | – |

