### single: 6000 characters at 300/s, 0 earlier messages, an update every 4 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| transcriptkit | 0/0 | – | – | – | – | – | – | – | – | – |
| transcriptkit-stream | 0/0 | – | – | – | – | – | – | – | – | – |
| transcriptkit-uikit | 0/0 | – | – | – | – | – | – | – | – | – |

### history: 6000 characters at 300/s, 50 earlier messages, an update every 4 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| transcriptkit | 3/3 | 0 | 0.0 | 16.7 | 2.59 | 4.73 | 43 | 43 | 58 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.7 | 1.49 | 3.03 | 43 | 43 | 54 | – |
| transcriptkit-uikit | 3/3 | 0 | 0.0 | 16.7 | 1.36 | 2.88 | 43 | 43 | 52 | – |

### burst: 20000 characters at 2000/s, 0 earlier messages, an update every 4 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| transcriptkit | 0/0 | – | – | – | – | – | – | – | – | – |
| transcriptkit-stream | 0/0 | – | – | – | – | – | – | – | – | – |
| transcriptkit-uikit | 0/0 | – | – | – | – | – | – | – | – | – |

### realistic: 6000 characters at 300/s, 50 earlier messages, an update every 33 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| transcriptkit | 3/3 | 0 | 0.0 | 16.7 | 1.48 | 2.19 | 46 | 46 | 54 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.7 | 1.10 | 1.87 | 43 | 43 | 54 | – |
| transcriptkit-uikit | 3/3 | 0 | 0.0 | 16.7 | 1.00 | 1.79 | 43 | 43 | 52 | – |

### scroll: scrolling through 50 earlier messages at 3000 points/s for 10 s

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| transcriptkit | 0/0 | – | – | – | – | – | – | – | – | – |
| transcriptkit-stream | 0/0 | – | – | – | – | – | – | – | – | – |
| transcriptkit-uikit | 0/0 | – | – | – | – | – | – | – | – | – |

