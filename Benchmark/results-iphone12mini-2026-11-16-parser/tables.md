### history: 6000 characters at 300/s, 50 earlier messages, an update every 4 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| none | 3/3 | 0 | 0.0 | 16.7 | 0.36 | 0.99 | 10 | 10 | 11 | – |
| transcriptkit | 3/3 | 0 | 0.0 | 16.8 | 4.33 | 6.83 | 39 | 39 | 63 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.8 | 1.86 | 4.58 | 36 | 36 | 63 | – |
| transcriptkit-uikit | 3/3 | 0 | 0.0 | 16.8 | 1.63 | 4.33 | 35 | 35 | 60 | – |

### burst: 20000 characters at 2000/s, 0 earlier messages, an update every 4 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| none | 3/3 | 0 | 0.0 | 16.7 | 0.20 | 0.53 | 11 | 11 | 12 | – |
| transcriptkit | 3/3 | 0 | 0.0 | 16.8 | 3.42 | 5.15 | 36 | 36 | 75 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.8 | 2.34 | 4.26 | 36 | 36 | 75 | – |
| transcriptkit-uikit | 3/3 | 0 | 0.0 | 16.8 | 1.87 | 3.84 | 47 | 47 | 68 | – |

### rich-history: 6000 characters at 300/s, 50 earlier messages, an update every 4 ms, rich text

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| none | 3/3 | 0 | 0.0 | 16.7 | 0.36 | 1.01 | 10 | 10 | 11 | – |
| transcriptkit | 3/3 | 0 | 0.0 | 16.8 | 4.20 | 7.28 | 50 | 50 | 92 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.8 | 2.25 | 5.51 | 65 | 65 | 92 | – |
| transcriptkit-uikit | 3/3 | 0 | 0.0 | 16.8 | 2.04 | 5.32 | 64 | 64 | 89 | – |

### rich-burst: 20000 characters at 2000/s, 0 earlier messages, an update every 4 ms, rich text

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| none | 3/3 | 0 | 0.0 | 16.7 | 0.19 | 0.53 | 11 | 11 | 12 | – |
| transcriptkit | 3/3 | 0 | 0.0 | 16.8 | 3.29 | 5.26 | 81 | 81 | 94 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.8 | 2.60 | 4.79 | 54 | 54 | 94 | – |
| transcriptkit-uikit | 3/3 | 0 | 0.0 | 16.8 | 2.27 | 4.51 | 48 | 48 | 95 | – |

