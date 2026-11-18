import Foundation

/// Deterministic Markdown shaped like a typical model answer: headings,
/// paragraphs with inline styles, lists and code blocks. No tables or other
/// elements added since 2026-11-16, so results stay comparable with earlier runs.
enum Corpus {
    static func section(_ index: Int) -> String {
        """
        ## Step \(index): caching the layout

        The renderer keeps **one layout per block** and reuses it while the *last block* grows. \
        When a chunk arrives, only `block \(index)` is measured again, so the cost of an update \
        does not depend on how long the conversation already is. See the \
        [design notes](https://example.com/notes/\(index)) for the details.

        A second paragraph adds some plain prose so that the text wraps over several lines on a \
        phone screen, which is what a real answer looks like most of the time.

        - First point about item \(index) with `inline code`
        - Second point with **strong emphasis** in the middle
          - A nested point that explains the second one
        - Third point, a little longer than the others so that it wraps onto another line

        ```swift
        func update\(index)(_ chunk: String) {
            parser.append(chunk)
            view.document = parser.document
            log("updated \(index)")
        }
        ```

        1. Measure the block
        2. Draw what is visible
        3. Repeat for the next chunk


        """
    }

    /// The same kind of answer using the elements added on 2026-11-16: a
    /// table taller than the bottom strip, with a row partway down that
    /// widens a column; citations near the start whose definitions come at
    /// the end (labels carry the section's index, so every section adds new
    /// definitions); strikethrough, an email address, a bare URL, entities,
    /// a little HTML, a task list with a nested numbered list, a nested
    /// quote and an image, shown as its alt text since no loader is set.
    static func richSection(_ index: Int, definitions: Bool = true) -> String {
        let text = """
        ## Step \(index): comparing the options

        The engine keeps **one layout per block**, as the [design notes][notes-\(index)] explain, and the \
        measurements in [\(index)] back that up. Earlier figures were ~~slower~~ taken before the strip; \
        questions go to perf-\(index)@example.com or https://example.com/faq/\(index).

        | Option | Main thread | Memory | Notes |
        | :--- | ---: | ---: | :--- |
        | Tiles | 1.9 s | 41 MB | drawn on scroll |
        | Tail strip | 1.6 s | 43 MB | *off the main thread* |
        | WebView | 2.6 s | 25 MB | another process |
        | Textual | 20.0 s | 150 MB | one view per message |
        | Option \(index) | 0.\(index % 10) s | \(40 + index % 7) MB | `measured` |
        | Native views with a much longer explanation in this cell that wraps | 3.1 s | 60 MB | baseline |
        | Metal | 1.7 s | 52 MB | dropped |
        | Core Animation | 1.8 s | 47 MB | kept |

        - [x] Parse off the main thread
        - [x] Draw the growing end on the layout queue
        - [ ] Profile again on the phone
          1. Record a trace
          1. Find the &ldquo;hot&rdquo; functions &mdash; then fix them
          1. Measure &amp; compare

        > The tail strip moves down as the text grows:
        >
        > > it is drawn off the main thread, <b>in the same commit</b> as the layout,<br>so nothing tears.

        ![chart for step \(index)](https://example.com/charts/\(index).png)

        ```swift
        let layout = DocumentLayout(document: document, width: 320)
        ```

        [notes-\(index)]: https://example.com/notes/\(index) "Design notes"
        [\(index)]: https://example.com/bench/\(index)


        """
        // For experiments: the same text without the definitions.
        return definitions ? text : text.replacingOccurrences(of: "\n[notes-\(index)]: https://example.com/notes/\(index) \"Design notes\"\n[\(index)]: https://example.com/bench/\(index)\n", with: "\n")
    }

    /// Which text to stream: `section` (the default) or `richSection`.
    static func section(_ index: Int, rich: Bool) -> String {
        rich ? richSection(index, definitions: !UserDefaults.standard.bool(forKey: "noDefinitions")) : section(index)
    }

    /// Markdown of at least `characters` characters, cut to exactly that length.
    static func response(characters: Int, startingAt first: Int = 1, rich: Bool = false) -> [Character] {
        var text = ""
        var index = first
        while text.count < characters {
            text += section(index, rich: rich)
            index += 1
        }
        return Array(text.prefix(characters))
    }

    /// Earlier messages of a conversation, each a few sections long.
    static func history(messages: Int, rich: Bool = false) -> [String] {
        (0..<messages).map { message in
            (1...2).map { section(message * 2 + $0, rich: rich) }.joined()
        }
    }
}
