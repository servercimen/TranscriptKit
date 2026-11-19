### history: 6000 characters at 300/s, 50 earlier messages, an update every 4 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| none | 3/3 | 0 | 0.0 | 16.8 | 0.38 | 1.06 | 10 | 10 | 11 | – |
| transcriptkit | 3/3 | 0 | 0.0 | 16.8 | 4.53 | 7.12 | 37 | 37 | 66 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.8 | 1.91 | 4.71 | 37 | 37 | 66 | – |
| transcriptkit-uikit | 3/3 | 0 | 0.0 | 16.8 | 1.67 | 4.46 | 37 | 37 | 63 | – |

### burst: 20000 characters at 2000/s, 0 earlier messages, an update every 4 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| none | 3/3 | 0 | 0.0 | 16.7 | 0.21 | 0.55 | 11 | 11 | 11 | – |
| transcriptkit | 3/3 | 0 | 0.0 | 16.8 | 3.38 | 5.17 | 51 | 51 | 79 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.8 | 2.39 | 4.37 | 41 | 41 | 79 | – |
| transcriptkit-uikit | 3/3 | 0 | 0.0 | 16.8 | 1.95 | 3.93 | 38 | 38 | 72 | – |

### scroll: scrolling through 50 earlier messages at 3000 points/s for 10 s

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| none | 3/3 | 0 | 0.0 | 16.7 | 0.01 | 0.01 | 11 | 11 | 11 | – |
| transcriptkit | 3/3 | 0 | 0.0 | 16.8 | 1.84 | 1.89 | 53 | 53 | 81 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.8 | 1.87 | 1.92 | 52 | 52 | 81 | – |
| transcriptkit-uikit | 3/3 | 0 | 0.0 | 16.8 | 1.46 | 1.50 | 49 | 49 | 77 | – |

### rich-history: 6000 characters at 300/s, 50 earlier messages, an update every 4 ms, rich text

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| none | 3/3 | 0 | 0.0 | 16.7 | 0.40 | 1.08 | 10 | 10 | 11 | – |
| transcriptkit | 3/3 | 0 | 0.0 | 16.8 | 4.28 | 7.39 | 52 | 52 | 97 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.8 | 2.31 | 5.63 | 58 | 58 | 97 | – |
| transcriptkit-uikit | 3/3 | 0 | 0.0 | 16.8 | 2.09 | 5.44 | 71 | 71 | 97 | – |

### rich-burst: 20000 characters at 2000/s, 0 earlier messages, an update every 4 ms, rich text

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| none | 3/3 | 0 | 0.0 | 16.7 | 0.20 | 0.54 | 11 | 11 | 12 | – |
| transcriptkit | 3/3 | 0 | 0.0 | 16.8 | 3.25 | 5.18 | 73 | 73 | 102 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.8 | 2.60 | 4.79 | 50 | 50 | 99 | – |
| transcriptkit-uikit | 3/3 | 0 | 0.0 | 16.8 | 2.26 | 4.54 | 57 | 57 | 103 | – |

### rich-scroll: scrolling through 50 earlier messages at 3000 points/s for 10 s, rich text

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| none | 3/3 | 0 | 0.0 | 16.7 | 0.01 | 0.01 | 11 | 11 | 11 | – |
| transcriptkit | 3/3 | 0 | 0.0 | 16.8 | 1.77 | 1.95 | 65 | 65 | 103 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.8 | 1.80 | 1.98 | 66 | 66 | 103 | – |
| transcriptkit-uikit | 3/3 | 0 | 0.0 | 16.8 | 1.42 | 1.66 | 60 | 60 | 85 | – |

