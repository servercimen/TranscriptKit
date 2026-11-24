import SwiftUI
import TranscriptKit

@main
struct DemoApp: App {
    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("-replacementCheck") {
                ReplacementCheckView()
            } else {
                ContentView()
            }
        }
    }
}

struct ContentView: View {
    @State private var transcript = Sample.initialStream()
    /// With `-documentPath`, the view is fed whole documents through SwiftUI
    /// instead of reading the stream directly. For comparing the two.
    private let usesDocumentPath = ProcessInfo.processInfo.arguments.contains("-documentPath")
    @State private var document = TranscriptDocument()
    @State private var streaming: Task<Void, Never>?
    @State private var tappedLink: URL?

    var body: some View {
        NavigationStack {
            ScrollView {
                Group {
                    if usesDocumentPath {
                        TranscriptText(document)
                    } else {
                        TranscriptText(stream: transcript)
                    }
                }
                .padding(16)
            }
            .defaultScrollAnchor(.top)
            // Show tapped links instead of leaving the app.
            .environment(\.openURL, OpenURLAction { url in
                tappedLink = url
                return .handled
            })
            .safeAreaInset(edge: .bottom) {
                if let tappedLink {
                    Text("Tapped link: \(tappedLink.absoluteString)")
                        .font(.footnote)
                        .padding(10)
                        .frame(maxWidth: .infinity)
                        .background(.thinMaterial)
                }
            }
            .navigationTitle("TranscriptKit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reset") {
                        streaming?.cancel()
                        streaming = nil
                        transcript = Sample.initialStream()
                        document = transcript.document
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(streaming == nil ? "Stream" : "Stop") {
                        if let streaming {
                            streaming.cancel()
                            self.streaming = nil
                        } else {
                            streaming = Task { await stream() }
                        }
                    }
                }
            }
        }
        .task {
            document = transcript.document
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-autostream") {
                streaming = Task { await stream() }
            }
            if arguments.contains("-demoSelection") {
                try? await Task.sleep(for: .seconds(1))
                DebugSelection.selectAcrossBlocks()
            }
        }
    }

    /// Feeds a fake model response to the stream a few characters at a time.
    private func stream() async {
        // `-slowStream` stretches the response over about 15 seconds, for testing gestures.
        let pause = ProcessInfo.processInfo.arguments.contains("-slowStream") ? 90 : 20
        var pending = Substring(Sample.streamedMarkdown)
        // The document path uses its own parser, so no `TranscriptStream` (and
        // no display link) is involved at all.
        var parser = MarkdownStreamParser()
        parser.append(Sample.intro)
        while !pending.isEmpty, !Task.isCancelled {
            let size = Int.random(in: 1...6)
            if usesDocumentPath {
                parser.append(String(pending.prefix(size)))
                document = parser.document
            } else {
                transcript.append(String(pending.prefix(size)))
            }
            pending = pending.dropFirst(size)
            try? await Task.sleep(for: .milliseconds(pause))
        }
        if usesDocumentPath {
            parser.finish()
            document = parser.document
        } else {
            transcript.finish()
        }
        streaming = nil
    }
}

enum Sample {
    static func initialStream() -> TranscriptStream {
        if ProcessInfo.processInfo.arguments.contains("-longDocument") {
            // A long transcript for checking memory use and scrolling.
            let sections = (1...1500).map { index in
                "## Section \(index)\n\nParagraph \(index) with **bold**, *italic* and `code`, long enough to wrap onto a second and a third line on a phone screen.\n\n"
            }
            return TranscriptStream(markdown: sections.joined())
        }
        return TranscriptStream(markdown: intro)
    }

    static let intro = """
    # One selection, many blocks

    Long-press any word, then drag a handle through the **heading**, the *paragraphs*, the list and the `code block`. Everything is drawn with Core Text into a single view.

    - Markdown is parsed as it streams
    - Only the last block is laid out again
      - Earlier blocks are frozen

    > Tap **Stream** to append a response a few characters at a time.


    """

    static let streamedMarkdown = """
    ## A streamed answer

    Here is a response with **bold text**, *italics*, ~~strikethrough~~, `inline code`, a [link](https://example.com) and a bare https://example.org/docs link. Markup is styled as soon as it opens, so nothing flickers when the closing marker arrives. The [design notes][notes] and the paper [1] are defined at the very end.

    1. Install the package
    1. Create a `MarkdownStreamParser`
    1. Append chunks as they arrive:

       ```swift
       stream.append(chunk)
       ```

    - [x] Parse off the main thread
    - [x] Draw the tail off the main thread
    - [ ] Fetch images (the app decides)

    | Element | Streams | Notes |
    | :--- | :---: | ---: |
    | Tables | yes | rows appear as they arrive |
    | Task lists | yes | drawn as boxes |
    | Images | alt text | ![a diagram](https://example.com/diagram.png) |

    > Quotes can hold other blocks:
    >
    > > a nested quote, with <b>simple HTML</b>, entities like &copy; &rarr; &#x1F600; and a<br>line break.

    Questions go to support@example.com.

    ---

    That is the whole loop.

    [notes]: https://example.com/notes "Design notes"
    [1]: https://example.com/paper


    """
}

/// Launch with `-replacementCheck` to replace the text of a card every two
/// seconds, with a short text and a long one in turn. Add `-crossfade` to lay
/// out each new text at once and crossfade to it. Add `-animatedSwap` to
/// swap inside `withAnimation`, so that the card's height animates. Each swap
/// logs when it happened, and each change of the card's height logs when
/// SwiftUI saw it.
struct ReplacementCheckView: View {
    @State private var showsLong = false
    @State private var swap = 0
    @State private var swapTime: CFTimeInterval = 0
    private let crossfades = ProcessInfo.processInfo.arguments.contains("-crossfade")
    private let animatesSwap = ProcessInfo.processInfo.arguments.contains("-animatedSwap")

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(crossfades ? "Crossfade, laid out at once" : "Laid out in the background")
                    .font(.footnote.monospaced())
                    .padding(.bottom, 8)
                TranscriptText(MarkdownStreamParser.document(from: showsLong ? Self.long : Self.short))
                    .crossfadesReplacedText(crossfades, duration: 0.6)
                    .padding(12)
                    .background(Color.yellow.opacity(0.35))
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        let delay = (CACurrentMediaTime() - swapTime) * 1000
                        print("replacement-check swap=\(swap) height=\(height) after=\(String(format: "%.1f", delay)) ms")
                    }
                Rectangle()
                    .fill(.red)
                    .frame(height: 8)
            }
            .padding(16)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                swap += 1
                swapTime = CACurrentMediaTime()
                print("replacement-check swap=\(swap) long=\(!showsLong)")
                if animatesSwap {
                    withAnimation(.easeInOut(duration: 0.6)) { showsLong.toggle() }
                } else {
                    showsLong.toggle()
                }
            }
        }
    }

    static let short = """
    ## Summary

    The build has **two steps**. The details come in two seconds.
    """

    static let long = """
    ## Details

    The first step compiles the package. The second step runs the tests on the device, and each step writes its \
    log to the `build` folder.

    1. Compile the package.
    2. Run the tests.
    3. Read the log, and run a step again with `--verbose` if it fails.

    > A step that fails twice needs a look at the [guide](https://example.com/guide).
    """
}

/// Launch with `-demoSelection` to select a range that starts in the heading
/// and ends inside the code block, without touching the screen. Useful for
/// screenshots and for checking the selection path from the command line.
@MainActor
enum DebugSelection {
    static func selectAcrossBlocks() {
        guard let view = findTranscriptView() else { return }
        view.becomeFirstResponder()
        view.select(4..<330)
    }

    private static func findTranscriptView() -> TranscriptTextView? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        for window in windows {
            if let found = search(window) { return found }
        }
        return nil
    }

    private static func search(_ view: UIView) -> TranscriptTextView? {
        if let match = view as? TranscriptTextView { return match }
        for subview in view.subviews {
            if let found = search(subview) { return found }
        }
        return nil
    }
}
