### single: 6000 characters at 300/s, 0 earlier messages, an update every 4 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| none | 0/0 | – | – | – | – | – | – | – | – | – |
| transcriptkit-stream | 0/0 | – | – | – | – | – | – | – | – | – |
| transcriptkit-uikit | 0/0 | – | – | – | – | – | – | – | – | – |
| textual | 0/0 | – | – | – | – | – | – | – | – | – |
| webview | 0/0 | – | – | – | – | – | – | – | – | – |

### history: 6000 characters at 300/s, 50 earlier messages, an update every 4 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| none | 0/0 | – | – | – | – | – | – | – | – | – |
| transcriptkit-stream | 0/0 | – | – | – | – | – | – | – | – | – |
| transcriptkit-uikit | 0/0 | – | – | – | – | – | – | – | – | – |
| textual | 0/0 | – | – | – | – | – | – | – | – | – |
| webview | 0/0 | – | – | – | – | – | – | – | – | – |

### burst: 20000 characters at 2000/s, 0 earlier messages, an update every 4 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| none | 0/0 | – | – | – | – | – | – | – | – | – |
| transcriptkit-stream | 0/0 | – | – | – | – | – | – | – | – | – |
| transcriptkit-uikit | 0/0 | – | – | – | – | – | – | – | – | – |
| textual | 0/0 | – | – | – | – | – | – | – | – | – |
| webview | 0/0 | – | – | – | – | – | – | – | – | – |

### realistic: 6000 characters at 300/s, 50 earlier messages, an update every 33 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| none | 0/0 | – | – | – | – | – | – | – | – | – |
| transcriptkit-stream | 0/0 | – | – | – | – | – | – | – | – | – |
| transcriptkit-uikit | 0/0 | – | – | – | – | – | – | – | – | – |
| textual | 0/0 | – | – | – | – | – | – | – | – | – |
| webview | 0/0 | – | – | – | – | – | – | – | – | – |

### scroll: scrolling through 50 earlier messages at 3000 points/s for 10 s

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| none | 3/3 | 0 | 0.0 | 16.7 | 0.01 | 0.01 | 11 | 11 | 11 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.8 | 1.74 | 1.81 | 58 | 58 | 76 | – |
| transcriptkit-uikit | 3/3 | 0 | 0.0 | 16.8 | 1.38 | 1.42 | 51 | 51 | 75 | – |
| textual | 3/3 | 14 | 19.6 | 143.3 | 4.46 | 4.60 | 125 | 125 | 151 | – |
| webview | 3/3 | 0 | 0.0 | 16.8 | 0.89 | 1.24 | 11 | 11 | 12 | 0 |

