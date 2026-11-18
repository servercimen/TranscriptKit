### single: 6000 characters at 300/s, 0 earlier messages

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Memory after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|
| transcriptkit | 3/3 | 0 | 0.0 | 16.7 | 5.85 | 41 | 117 | – |
| textual | 3/3 | 25 | 19.6 | 74.3 | 14.28 | 74 | 100 | – |
| textual-noselect | 3/3 | 18 | 14.4 | 83.0 | 13.96 | 73 | 97 | – |
| webview | 3/3 | 0 | 0.0 | 16.7 | 2.53 | 26 | 27 | 1 |

### history: 6000 characters at 300/s, 50 earlier messages

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Memory after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|
| transcriptkit | 3/3 | 0 | 0.0 | 16.7 | 13.92 | 41 | 83 | – |
| textual | 3/3 | 37 | 29.1 | 153.0 | 15.71 | 173 | 225 | – |
| textual-noselect | 3/3 | 34 | 26.8 | 152.7 | 15.40 | 167 | 211 | – |
| webview | 3/3 | 0 | 0.0 | 16.7 | 2.44 | 31 | 31 | 0 |

### burst: 20000 characters at 2000/s, 0 earlier messages

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Memory after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|
| transcriptkit | 3/3 | 0 | 0.0 | 16.7 | 3.56 | 42 | 84 | – |
| textual | 3/3 | 359 | 541.9 | 221.1 | 9.58 | 186 | 254 | – |
| textual-noselect | 3/3 | 331 | 500.6 | 155.2 | 9.47 | 185 | 253 | – |
| webview | 3/3 | 0 | 0.0 | 16.7 | 1.54 | 56 | 57 | 1 |

