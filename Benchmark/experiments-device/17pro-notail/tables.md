### single: 6000 characters at 300/s, 0 earlier messages, an update every 4 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| transcriptkit | 0/0 | – | – | – | – | – | – | – | – | – |
| transcriptkit-stream | 0/0 | – | – | – | – | – | – | – | – | – |
| transcriptkit-uikit | 0/0 | – | – | – | – | – | – | – | – | – |

### history: 6000 characters at 300/s, 50 earlier messages, an update every 4 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| transcriptkit | 3/3 | 0 | 0.0 | 16.7 | 2.44 | 3.07 | 62 | 62 | 77 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 25.0 | 1.42 | 2.09 | 55 | 55 | 78 | – |
| transcriptkit-uikit | 3/3 | 0 | 0.0 | 16.7 | 1.29 | 1.95 | 62 | 62 | 77 | – |

### burst: 20000 characters at 2000/s, 0 earlier messages, an update every 4 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| transcriptkit | 0/0 | – | – | – | – | – | – | – | – | – |
| transcriptkit-stream | 0/0 | – | – | – | – | – | – | – | – | – |
| transcriptkit-uikit | 0/0 | – | – | – | – | – | – | – | – | – |

### realistic: 6000 characters at 300/s, 50 earlier messages, an update every 33 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| transcriptkit | 3/3 | 0 | 0.0 | 16.7 | 1.17 | 1.38 | 55 | 55 | 65 | – |
| transcriptkit-stream | 3/3 | 2 | 0.0 | 25.0 | 0.91 | 1.17 | 55 | 55 | 64 | – |
| transcriptkit-uikit | 3/3 | 0 | 0.0 | 16.7 | 0.81 | 1.05 | 54 | 54 | 65 | – |

### scroll: scrolling through 50 earlier messages at 3000 points/s for 10 s

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| transcriptkit | 0/0 | – | – | – | – | – | – | – | – | – |
| transcriptkit-stream | 0/0 | – | – | – | – | – | – | – | – | – |
| transcriptkit-uikit | 0/0 | – | – | – | – | – | – | – | – | – |

