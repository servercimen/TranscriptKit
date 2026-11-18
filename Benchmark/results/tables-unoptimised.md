### single: 6000 characters at 300/s, 0 earlier messages, an update every 4 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Memory after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|
| transcriptkit | 3/3 | 0 | 0.0 | 16.7 | 3.83 | 37 | 47 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.7 | 2.16 | 37 | 47 | – |
| textual | 3/3 | 41 | 31.6 | 65.8 | 14.43 | 74 | 97 | – |
| textual-noselect | 3/3 | 24 | 19.1 | 74.0 | 14.25 | 73 | 98 | – |
| webview | 3/3 | 0 | 0.0 | 16.7 | 2.49 | 27 | 27 | 0 |

### history: 6000 characters at 300/s, 50 earlier messages, an update every 4 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Memory after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|
| transcriptkit | 3/3 | 0 | 0.0 | 16.7 | 4.23 | 37 | 49 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.7 | 2.36 | 37 | 48 | – |
| textual | 3/3 | 54 | 42.8 | 165.4 | 15.61 | 173 | 225 | – |
| textual-noselect | 3/3 | 39 | 30.8 | 152.0 | 15.34 | 166 | 211 | – |
| webview | 3/3 | 0 | 0.0 | 16.7 | 2.42 | 31 | 31 | 0 |

### burst: 20000 characters at 2000/s, 0 earlier messages, an update every 4 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Memory after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|
| transcriptkit | 3/3 | 0 | 0.0 | 16.7 | 2.33 | 36 | 54 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.7 | 1.60 | 36 | 54 | – |
| textual | 3/3 | 355 | 526.4 | 213.3 | 9.50 | 186 | 254 | – |
| textual-noselect | 3/3 | 330 | 501.9 | 178.2 | 9.44 | 185 | 252 | – |
| webview | 3/3 | 0 | 0.0 | 16.7 | 1.53 | 57 | 57 | 2 |

### realistic: 6000 characters at 300/s, 50 earlier messages, an update every 33 ms

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Memory after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|
| transcriptkit | 3/3 | 0 | 0.0 | 16.7 | 2.15 | 37 | 48 | – |
| transcriptkit-stream | 3/3 | 0 | 0.0 | 16.7 | 1.68 | 37 | 48 | – |
| textual | 3/3 | 46 | 36.7 | 199.9 | 7.50 | 173 | 225 | – |
| textual-noselect | 3/3 | 44 | 34.9 | 171.9 | 7.25 | 165 | 210 | – |
| webview | 3/3 | 0 | 0.0 | 16.7 | 1.43 | 21 | 21 | 0 |

