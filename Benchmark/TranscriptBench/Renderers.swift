import SwiftUI
import Textual
import TranscriptKit
import WebKit

// MARK: - TranscriptKit

/// The whole conversation is one document in one view.
struct TranscriptKitRenderer: View {
    let document: TranscriptDocument

    var body: some View {
        ScrollView {
            TranscriptText(document)
                .padding(16)
        }
        .defaultScrollAnchor(.bottom)
    }
}

/// The same view fed by a `TranscriptStream`: chunks reach the view once per
/// frame without a SwiftUI update.
struct TranscriptKitStreamRenderer: View {
    let stream: TranscriptStream

    var body: some View {
        ScrollView {
            TranscriptText(stream: stream)
                .padding(16)
        }
        .defaultScrollAnchor(.bottom)
    }
}

/// The same view in a UIScrollView with Auto Layout, without SwiftUI in the
/// update loop: a height change updates the scroll view's content size
/// directly. The scroll position follows the bottom, as a chat does.
struct TranscriptKitUIKitRenderer: UIViewRepresentable {
    let stream: TranscriptStream

    func makeUIView(context: Context) -> BottomFollowingScrollView {
        let scrollView = BottomFollowingScrollView()
        let text = TranscriptTextView()
        text.stream = stream
        text.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 16),
            text.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -16),
            text.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
            text.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -16),
            text.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -32),
        ])
        return scrollView
    }

    func updateUIView(_ view: BottomFollowingScrollView, context: Context) {}
}

/// Keeps the bottom in view while the content grows, unless the user (or the
/// benchmark's scroller) has moved away from it.
final class BottomFollowingScrollView: UIScrollView {
    private var lastContentHeight: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        guard contentSize.height != lastContentHeight else { return }
        let bottom = contentSize.height - bounds.height + adjustedContentInset.bottom
        let wasAtBottom = contentOffset.y >= lastContentHeight - bounds.height + adjustedContentInset.bottom - 4
        lastContentHeight = contentSize.height
        if wasAtBottom { contentOffset.y = max(bottom, -adjustedContentInset.top) }
    }
}

// MARK: - Textual

/// One `StructuredText` per message in a lazy stack, the usual way to build a
/// chat transcript with a per-message Markdown view.
struct TextualRenderer: View {
    let history: [String]
    let current: String
    let selectable: Bool

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(history.indices, id: \.self) { index in
                    message(history[index])
                }
                message(current)
            }
            .padding(16)
        }
        .defaultScrollAnchor(.bottom)
    }

    @ViewBuilder
    private func message(_ markdown: String) -> some View {
        if selectable {
            StructuredText(markdown: markdown)
                .textual.textSelection(.enabled)
        } else {
            StructuredText(markdown: markdown)
        }
    }
}

// MARK: - WKWebView

/// A page whose last message is replaced with freshly rendered HTML on every
/// chunk. Markdown is converted to HTML natively (with TranscriptKit's parser)
/// rather than by a JavaScript library in the page, so this measures WebKit as
/// a renderer, not a JavaScript Markdown parser.
@MainActor
final class WebRenderer {
    let webView = WKWebView(frame: .zero)

    private static let page = """
    <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
    body { font: -apple-system-body; margin: 16px; color: #000; background: #fff; }
    h1 { font-size: 1.5em; } h2 { font-size: 1.3em; } h3 { font-size: 1.15em; }
    pre { background: #eee; padding: 12px; border-radius: 8px; white-space: pre-wrap; font-size: 0.88em; }
    code { font-family: ui-monospace, Menlo, monospace; }
    blockquote { border-left: 3px solid #bbb; margin: 0; padding-left: 11px; }
    .li { display: flex; margin: 6px 0; } .li > span { min-width: 24px; }
    .message { margin-bottom: 16px; }
    </style></head><body><div id="history"></div><div id="current" class="message"></div>
    <script>
    var intervals = [], last = 0;
    function tick(t) { if (last) intervals.push(t - last); last = t; requestAnimationFrame(tick); }
    requestAnimationFrame(tick);
    function resetFrames() { intervals = []; last = 0; }
    function frames() { return JSON.stringify(intervals); }
    function setHistory(html) { document.getElementById('history').innerHTML = html; window.scrollTo(0, document.body.scrollHeight); }
    function setCurrent(html) { document.getElementById('current').innerHTML = html; window.scrollTo(0, document.body.scrollHeight); }
    </script></body></html>
    """

    func load() async {
        webView.loadHTMLString(Self.page, baseURL: nil)
        while webView.isLoading { try? await Task.sleep(for: .milliseconds(50)) }
    }

    private func call(_ function: String, _ argument: String) async {
        let literal = String(data: try! JSONEncoder().encode(argument), encoding: .utf8)!
        _ = try? await webView.evaluateJavaScript("\(function)(\(literal)); 0")
    }

    func setHistory(_ messages: [String]) async {
        let html = messages
            .map { "<div class=\"message\">\(HTML.render(MarkdownStreamParser.document(from: $0)))</div>" }
            .joined()
        await call("setHistory", html)
    }

    func setCurrent(_ document: TranscriptDocument) async {
        await call("setCurrent", HTML.render(document))
    }

    func resetFrames() async {
        _ = try? await webView.evaluateJavaScript("resetFrames(); 0")
    }

    /// Gaps between `requestAnimationFrame` callbacks inside the page, in seconds.
    func frameIntervals() async -> [Double] {
        guard let json = try? await webView.evaluateJavaScript("frames()") as? String,
              let values = try? JSONDecoder().decode([Double].self, from: Data(json.utf8)) else { return [] }
        return values.map { $0 / 1000 }
    }
}

struct WebRendererView: UIViewRepresentable {
    let renderer: WebRenderer

    func makeUIView(context: Context) -> WKWebView { renderer.webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}

enum HTML {
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func inline(_ block: TranscriptBlock) -> String {
        let text = block.text as NSString
        var cuts: Set<Int> = [0, text.length]
        for span in block.spans {
            cuts.insert(min(span.range.lowerBound, text.length))
            cuts.insert(min(span.range.upperBound, text.length))
        }
        let sorted = cuts.sorted()
        var html = ""
        for (lower, upper) in zip(sorted, sorted.dropFirst()) {
            var piece = escape(text.substring(with: NSRange(location: lower, length: upper - lower)))
            for span in block.spans where span.range.lowerBound <= lower && span.range.upperBound >= upper {
                if span.traits.contains(.code) { piece = "<code>\(piece)</code>" }
                if span.traits.contains(.bold) { piece = "<b>\(piece)</b>" }
                if span.traits.contains(.italic) { piece = "<i>\(piece)</i>" }
                if let link = span.link { piece = "<a href=\"\(escape(link))\">\(piece)</a>" }
            }
            html += piece
        }
        return html
    }

    static func render(_ document: TranscriptDocument) -> String {
        var html = ""
        for block in document.blocks {
            var body: String
            switch block.kind {
            case .paragraph: body = "<p>\(inline(block))</p>"
            case .heading(let level): body = "<h\(level)>\(inline(block))</h\(level)>"
            case .code: body = "<pre><code>\(escape(block.text))</code></pre>"
            case .rule: body = "<hr>"
            case .table(let table):
                let text = block.text as NSString
                body = "<table>" + table.rows.enumerated().map { index, row in
                    let tag = index == 0 ? "th" : "td"
                    return "<tr>" + row.map { "<\(tag)>\(escape(text.substring(with: NSRange(location: $0.lowerBound, length: $0.count))))</\(tag)>" }.joined() + "</tr>"
                }.joined() + "</table>"
            }
            // Containers as nested wrappers, innermost first.
            for (index, container) in block.containers.enumerated().reversed() {
                switch container {
                case .quote:
                    body = "<blockquote>\(body)</blockquote>"
                case .listItem:
                    var marker = ""
                    if index == block.containers.lastIndex(of: .listItem), let kind = block.marker {
                        switch kind {
                        case .bullet: marker = "•"
                        case .number(let number): marker = number
                        case .task(let checked): marker = checked ? "☑" : "☐"
                        }
                    }
                    body = "<div class=\"li\"><span>\(marker)</span><div>\(body)</div></div>"
                }
            }
            html += body
        }
        return html
    }
}
