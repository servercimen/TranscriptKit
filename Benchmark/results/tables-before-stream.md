### single: 6000 characters at 300/s, 0 earlier messages

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Memory after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|
| transcriptkit | 3/3 | 0 | 0.0 | 16.7 | 4.66 | 37 | 47 | – |
| textual | 3/3 | 41 | 31.6 | 65.8 | 14.43 | 74 | 97 | – |
| textual-noselect | 3/3 | 24 | 19.1 | 74.0 | 14.25 | 73 | 98 | – |
| webview | 3/3 | 0 | 0.0 | 16.7 | 2.49 | 27 | 27 | 0 |

### history: 6000 characters at 300/s, 50 earlier messages

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Memory after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|
| transcriptkit | 3/3 | 0 | 0.0 | 16.7 | 4.92 | 37 | 50 | – |
| textual | 3/3 | 54 | 42.8 | 165.4 | 15.61 | 173 | 225 | – |
| textual-noselect | 3/3 | 39 | 30.8 | 152.0 | 15.34 | 166 | 211 | – |
| webview | 3/3 | 0 | 0.0 | 16.7 | 2.42 | 31 | 31 | 0 |

### burst: 20000 characters at 2000/s, 0 earlier messages

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Memory after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|
| transcriptkit | 3/3 | 0 | 0.0 | 16.7 | 2.40 | 35 | 57 | – |
| textual | 3/3 | 355 | 526.4 | 213.3 | 9.50 | 186 | 254 | – |
| textual-noselect | 3/3 | 330 | 501.9 | 178.2 | 9.44 | 185 | 252 | – |
| webview | 3/3 | 0 | 0.0 | 16.7 | 1.53 | 57 | 57 | 2 |

