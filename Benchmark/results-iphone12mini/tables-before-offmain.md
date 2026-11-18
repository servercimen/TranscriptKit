### single: 6000 characters at 300/s, 0 earlier messages, an update every 4 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| transcriptkit | 3/3 | 0 | 0.0 | 16.8 | 6.28 | 7.13 | 55 | 55 | 66 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.8 | 3.36 | 4.20 | 55 | 55 | 66 | – |

### history: 6000 characters at 300/s, 50 earlier messages, an update every 4 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| transcriptkit | 3/3 | 0 | 0.0 | 16.8 | 6.75 | 7.58 | 46 | 46 | 49 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.8 | 3.53 | 4.35 | 46 | 46 | 49 | – |

### burst: 20000 characters at 2000/s, 0 earlier messages, an update every 4 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| transcriptkit | 3/3 | 0 | 0.0 | 16.8 | 4.49 | 4.88 | 34 | 34 | 87 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.8 | 3.53 | 3.92 | 34 | 34 | 82 | – |

### realistic: 6000 characters at 300/s, 50 earlier messages, an update every 33 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|---|---|
| transcriptkit | 3/3 | 0 | 0.0 | 16.8 | 2.80 | 3.00 | 39 | 39 | 42 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.8 | 2.27 | 2.62 | 39 | 39 | 42 | – |

