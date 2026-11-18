### single: 6000 characters at 300/s, 0 earlier messages, an update every 4 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| transcriptkit | 3/3 | 0 | 0.0 | 16.7 | 3.30 | 3.75 | 37 | 37 | 47 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.7 | 2.03 | 2.45 | 37 | 37 | 46 | – |

### history: 6000 characters at 300/s, 50 earlier messages, an update every 4 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| transcriptkit | 3/3 | 0 | 0.0 | 16.7 | 3.88 | 4.35 | 37 | 37 | 48 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.7 | 2.15 | 2.56 | 37 | 37 | 48 | – |

### burst: 20000 characters at 2000/s, 0 earlier messages, an update every 4 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| transcriptkit | 3/3 | 1 | 1.5 | 33.3 | 2.19 | 2.42 | 35 | 35 | 54 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.7 | 1.61 | 1.79 | 35 | 35 | 56 | – |

### realistic: 6000 characters at 300/s, 50 earlier messages, an update every 33 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| transcriptkit | 3/3 | 0 | 0.0 | 16.7 | 1.96 | 2.11 | 37 | 37 | 49 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.7 | 1.48 | 1.61 | 37 | 37 | 49 | – |

