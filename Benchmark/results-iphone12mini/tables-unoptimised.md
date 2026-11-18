### single: 6000 characters at 300/s, 0 earlier messages

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Memory after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|
| transcriptkit | 3/3 | 0 | 0.0 | 16.8 | 7.92 | 50 | 66 | – |
| textual | 3/3 | 26 | 20.1 | 71.7 | 15.74 | 63 | 103 | – |
| textual-noselect | 3/3 | 23 | 16.9 | 65.3 | 15.58 | 65 | 98 | – |
| webview | 3/3 | 0 | 0.0 | 16.8 | 2.72 | 25 | 25 | 1 |

### history: 6000 characters at 300/s, 50 earlier messages

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Memory after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|
| transcriptkit | 3/3 | 0 | 0.0 | 16.8 | 8.51 | 46 | 49 | – |
| textual | 3/3 | 493 | 375.2 | 61.7 | 20.05 | 179 | 181 | – |
| textual-noselect | 3/3 | 486 | 368.7 | 92.7 | 20.05 | 165 | 167 | – |
| webview | 3/3 | 0 | 0.0 | 16.8 | 2.76 | 24 | 24 | 0 |

### burst: 20000 characters at 2000/s, 0 earlier messages

| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Memory after MB | Memory peak MB | Page dropped frames |
|---|---|---|---|---|---|---|---|---|
| transcriptkit | 3/3 | 0 | 0.0 | 16.8 | 4.65 | 34 | 88 | – |
| textual | 3/3 | 324 | 482.2 | 207.6 | 9.70 | 170 | 239 | – |
| textual-noselect | 3/3 | 308 | 456.2 | 153.9 | 9.67 | 169 | 238 | – |
| webview | 3/3 | 0 | 0.0 | 16.8 | 1.68 | 51 | 51 | 0 |

