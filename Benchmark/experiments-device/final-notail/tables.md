### single: 6000 characters at 300/s, 0 earlier messages, an update every 4 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| transcriptkit | 0/0 | – | – | – | – | – | – | – | – | – |
| transcriptkit-stream | 0/0 | – | – | – | – | – | – | – | – | – |
| transcriptkit-uikit | 0/0 | – | – | – | – | – | – | – | – | – |

### history: 6000 characters at 300/s, 50 earlier messages, an update every 4 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| transcriptkit | 3/3 | 0 | 0.0 | 16.8 | 5.12 | 6.49 | 52 | 52 | 55 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.8 | 2.78 | 4.34 | 52 | 52 | 55 | – |
| transcriptkit-uikit | 3/3 | 0 | 0.0 | 16.8 | 2.51 | 4.02 | 52 | 52 | 52 | – |

### burst: 20000 characters at 2000/s, 0 earlier messages, an update every 4 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| transcriptkit | 0/0 | – | – | – | – | – | – | – | – | – |
| transcriptkit-stream | 0/0 | – | – | – | – | – | – | – | – | – |
| transcriptkit-uikit | 0/0 | – | – | – | – | – | – | – | – | – |

### realistic: 6000 characters at 300/s, 50 earlier messages, an update every 33 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| transcriptkit | 3/3 | 0 | 0.0 | 16.8 | 2.41 | 2.88 | 39 | 39 | 49 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.8 | 1.86 | 2.40 | 45 | 45 | 48 | – |
| transcriptkit-uikit | 3/3 | 0 | 0.0 | 16.8 | 1.56 | 2.08 | 45 | 45 | 46 | – |

### scroll: scrolling through 50 earlier messages at 3000 points/s for 10 s

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| transcriptkit | 0/0 | – | – | – | – | – | – | – | – | – |
| transcriptkit-stream | 0/0 | – | – | – | – | – | – | – | – | – |
| transcriptkit-uikit | 0/0 | – | – | – | – | – | – | – | – | – |

