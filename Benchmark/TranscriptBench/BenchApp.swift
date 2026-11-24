import SwiftUI
@_spi(Diagnostics) import TranscriptKit

/// Streams the same Markdown through one renderer, measures frame pacing, CPU
/// and memory, prints one `BENCH_RESULT {json}` line and exits.
///
/// Launch arguments:
///   -renderer none | transcriptkit | transcriptkit-stream | textual | textual-noselect | webview
///                            (none streams into nothing, to measure the harness itself)
///   -scenario <label>        name recorded in the result
///   -chars <n>               length of the streamed response
///   -rate <n>                characters per second
///   -history <n>             messages already in the conversation
///   -interval <ms>           pause between updates (default 4)
///   -hold 1                  stay open after the run instead of exiting
///   -noTail 1                TranscriptKit draws the growing end on the main thread, as before
///   -mode scroll             scroll through the history instead of streaming
///   -mode many               replace the documents of many texts at once (see `ManyTextsModel`)
///   -scrollSeconds <s>       how long to scroll (default 10)
///   -scrollSpeed <pt/s>      scrolling speed (default 3000)
///   -corpus rich             stream `Corpus.richSection` text instead of the default
///   -noDefinitions 1         with -corpus rich: leave out the link definitions (an experiment)
@main
struct BenchApp: App {
    init() {
        // `-noTail 1` draws everything in tiles on the main thread, to compare.
        if UserDefaults.standard.bool(forKey: "noTail") {
            TranscriptDiagnostics.drawsTailOffMainThread = false
        }
    }

    var body: some Scene {
        WindowGroup {
            BenchRoot()
        }
    }
}

struct Config {
    var renderer = "transcriptkit"
    var scenario = "single"
    var characters = 6000
    var rate = 300
    var history = 0
    var intervalMs = 4
    /// "stream" appends the response; "scroll" scrolls through the history instead.
    var mode = "stream"
    var scrollSeconds = 10.0
    var scrollSpeed = 3000.0
    /// "answer" (the default text) or "rich" (tables, references and the rest).
    var corpus = "answer"
    var rich: Bool { corpus == "rich" }

    init() {
        let defaults = UserDefaults.standard
        if let value = defaults.string(forKey: "renderer") { renderer = value }
        if let value = defaults.string(forKey: "scenario") { scenario = value }
        if defaults.object(forKey: "chars") != nil { characters = defaults.integer(forKey: "chars") }
        if defaults.object(forKey: "rate") != nil { rate = defaults.integer(forKey: "rate") }
        if defaults.object(forKey: "history") != nil { history = defaults.integer(forKey: "history") }
        if defaults.object(forKey: "interval") != nil { intervalMs = max(defaults.integer(forKey: "interval"), 1) }
        if let value = defaults.string(forKey: "mode") { mode = value }
        if defaults.object(forKey: "scrollSeconds") != nil { scrollSeconds = defaults.double(forKey: "scrollSeconds") }
        if defaults.object(forKey: "scrollSpeed") != nil { scrollSpeed = defaults.double(forKey: "scrollSpeed") }
        if let value = defaults.string(forKey: "corpus") { corpus = value }
    }
}

@MainActor
@Observable
final class BenchModel {
    let config = Config()
    let web = WebRenderer()

    var parser = MarkdownStreamParser()
    /// Not observed: the view reads it directly, so SwiftUI never sees its updates.
    @ObservationIgnored let stream = TranscriptStream()
    var history: [String] = []
    var current = ""

    private var response: [Character] = []
    @ObservationIgnored private var discarded = 0

    func run() async {
        if config.mode == "open" {
            await measureOpening()
            return
        }
        response = Corpus.response(characters: config.characters, startingAt: config.history * 2 + 1, rich: config.rich)
        let historyMessages = Corpus.history(messages: config.history, rich: config.rich)

        // Put the earlier conversation on screen before measuring.
        switch config.renderer {
        case "webview":
            await web.load()
            await web.setHistory(historyMessages)
        case "transcriptkit":
            for message in historyMessages { parser.append(message) }
        case "transcriptkit-stream", "transcriptkit-uikit":
            for message in historyMessages { stream.append(message) }
            stream.flush()
        case "none":
            break
        default:
            history = historyMessages
        }
        try? await Task.sleep(for: .seconds(2))

        let monitor = FrameMonitor()
        let memoryBefore = Memory.footprintMB().current
        await web.resetFramesIfNeeded(config.renderer)
        TranscriptDiagnostics.reset()
        let mainCPU = Clock.threadCPU()
        let processCPU = Clock.processCPU()
        monitor.start()

        // Chunk i is due at i / rate seconds. If the renderer falls behind,
        // the next append carries everything that is due, as a network stream would.
        var webParser = MarkdownStreamParser()
        let start = ContinuousClock.now
        var sent = 0
        while sent < response.count {
            let elapsed = ContinuousClock.now - start
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let due = min(response.count, Int(seconds * Double(config.rate)))
            if due > sent {
                let chunk = String(response[sent..<due])
                sent = due
                switch config.renderer {
                case "transcriptkit":
                    parser.append(chunk)
                case "transcriptkit-stream", "transcriptkit-uikit":
                    stream.append(chunk)
                case "webview":
                    webParser.append(chunk)
                    await web.setCurrent(webParser.document)
                case "none":
                    discarded += chunk.utf8.count
                default:
                    current += chunk
                }
            }
            try? await Task.sleep(for: .milliseconds(config.intervalMs))
        }
        if config.mode == "scroll", let scrollView = findScrollView() {
            // Scroll through the conversation at a steady speed, turning at the ends.
            let scroller = Scroller(scrollView: scrollView, speed: config.scrollSpeed)
            scroller.start()
            try? await Task.sleep(for: .seconds(config.scrollSeconds))
            scroller.stop()
        }
        // Let the last update reach the screen.
        try? await Task.sleep(for: .seconds(1))

        let frames = monitor.stop()
        let mainCPUUsed = Clock.threadCPU() - mainCPU
        let processCPUUsed = Clock.processCPU() - processCPU
        let counters = TranscriptDiagnostics.current
        let memory = Memory.footprintMB()
        malloc_zone_pressure_relief(nil, 0)
        let relievedMB = Memory.footprintMB().current
        var pageFrames: FrameStats?
        if config.renderer == "webview" {
            pageFrames = FrameStats(intervals: await web.frameIntervals(), frameDuration: frames.frameMs / 1000)
        }

        let result = BenchResult(
            renderer: config.renderer,
            scenario: config.scenario,
            characters: config.characters,
            charactersPerSecond: config.rate,
            historyMessages: config.history,
            frames: frames,
            pageFrames: pageFrames,
            mainThreadCPUSeconds: mainCPUUsed,
            processCPUSeconds: processCPUUsed,
            memoryBeforeMB: memoryBefore,
            memoryAfterMB: memory.current,
            memoryAfterReliefMB: relievedMB,
            memoryPeakMB: memory.peak,
            installs: counters.installs,
            tileDraws: counters.tileDraws,
            tailFrames: counters.tailFrames,
            screenMaxFPS: UIScreen.main.maximumFramesPerSecond,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: ProcessInfo.processInfo.thermalState.rawValue,
            corpus: config.corpus,
            osVersion: UIDevice.current.systemVersion,
            content: contentCounts()
        )
        let json = String(data: try! JSONEncoder().encode(result), encoding: .utf8)!
        print("BENCH_RESULT \(json)")
        fflush(stdout)
        // `-hold 1` keeps the app open afterwards, for looking at the result.
        if !UserDefaults.standard.bool(forKey: "hold") { exit(0) }
    }
}

extension BenchModel {
    /// What the TranscriptKit renderers ended up with, to show which code
    /// paths a run went through: blocks by kind, link definitions, and
    /// spans that are references, links, images or strikethrough.
    func contentCounts() -> [String: Int]? {
        let document: TranscriptDocument
        switch config.renderer {
        case "transcriptkit": document = parser.document
        case "transcriptkit-stream", "transcriptkit-uikit": document = stream.document
        default: return nil
        }
        var counts: [String: Int] = ["definitions": document.linkDefinitions.count]
        for index in 0..<document.count {
            let block = document.block(at: index)
            let kind: String
            switch block.kind {
            case .paragraph: kind = "paragraphs"
            case .heading: kind = "headings"
            case .code: kind = "codeBlocks"
            case .rule: kind = "rules"
            case .table: kind = "tables"
            }
            counts[kind, default: 0] += 1
            if !block.containers.isEmpty { counts["inContainers", default: 0] += 1 }
            if case .task? = block.marker { counts["tasks", default: 0] += 1 }
            for span in block.spans {
                if span.reference != nil { counts["references", default: 0] += 1 }
                if span.link != nil { counts["links", default: 0] += 1 }
                if span.image != nil { counts["images", default: 0] += 1 }
                if span.traits.contains(.strikethrough) { counts["strikethrough", default: 0] += 1 }
            }
        }
        return counts
    }
}

extension BenchModel {
    /// What opening a conversation of `history` messages costs when it is all
    /// parsed and laid out at once: parsing, then a full layout at the
    /// screen's width, each timed on the main thread. Prints OPEN_RESULT.
    func measureOpening() async {
        try? await Task.sleep(for: .seconds(1))
        let markdown = Corpus.history(messages: config.history, rich: config.rich).joined()
        let width = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.width ?? 375
        var parseMs: [Double] = []
        var layoutMs: [Double] = []
        var blocks = 0
        var height: CGFloat = 0
        for _ in 0..<5 {
            let t0 = ContinuousClock.now
            let document = MarkdownStreamParser.document(from: markdown)
            let t1 = ContinuousClock.now
            let layout = DocumentLayout(document: document, width: width - 32)
            let t2 = ContinuousClock.now
            parseMs.append(Double((t1 - t0).components.attoseconds) / 1e15 + Double((t1 - t0).components.seconds) * 1000)
            layoutMs.append(Double((t2 - t1).components.attoseconds) / 1e15 + Double((t2 - t1).components.seconds) * 1000)
            blocks = document.count
            height = layout.height
        }
        let median = { (values: [Double]) in values.sorted()[values.count / 2] }
        print("OPEN_RESULT {\"history\":\(config.history),\"characters\":\(markdown.count),\"blocks\":\(blocks),\"height\":\(Int(height)),\"parseMs\":\(median(parseMs)),\"layoutMs\":\(median(layoutMs))}")
        fflush(stdout)
        exit(0)
    }

    /// The scroll view showing the conversation: the largest one in the window.
    func findScrollView() -> UIScrollView? {
        if config.renderer == "webview" { return web.webView.scrollView }
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        var best: UIScrollView?
        func visit(_ view: UIView) {
            if let scrollView = view as? UIScrollView,
               scrollView.contentSize.height > (best?.contentSize.height ?? 0) {
                best = scrollView
            }
            view.subviews.forEach(visit)
        }
        windows.forEach(visit)
        return best
    }
}

/// Moves a scroll view by `speed` points per second of real time, so a slow
/// frame scrolls further, as a fling would.
@MainActor
final class Scroller: NSObject {
    private let scrollView: UIScrollView
    private let speed: Double
    private var direction = -1.0
    private var last: CFTimeInterval = 0
    private var link: CADisplayLink?

    init(scrollView: UIScrollView, speed: Double) {
        self.scrollView = scrollView
        self.speed = speed
    }

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        // The screen's full rate: 120 Hz on a ProMotion iPhone when the app
        // opts in (run.py --promotion), 60 Hz otherwise.
        let fastest = Float(UIScreen.main.maximumFramesPerSecond)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, fastest), maximum: fastest, preferred: fastest)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        defer { last = link.timestamp }
        guard last > 0 else { return }
        let top = -scrollView.adjustedContentInset.top
        let bottom = max(top, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
        var y = scrollView.contentOffset.y + direction * speed * (link.timestamp - last)
        if y < top { y = top; direction = 1 }
        if y > bottom { y = bottom; direction = -1 }
        scrollView.contentOffset.y = y
    }
}

private extension WebRenderer {
    func resetFramesIfNeeded(_ renderer: String) async {
        if renderer == "webview" { await resetFrames() }
    }
}

struct BenchRoot: View {
    var body: some View {
        if UserDefaults.standard.string(forKey: "mode") == "many" {
            ManyTextsRenderer()
        } else {
            BenchRendererRoot()
        }
    }
}

struct BenchRendererRoot: View {
    @State private var model = BenchModel()

    var body: some View {
        Group {
            switch model.config.renderer {
            case "transcriptkit":
                TranscriptKitRenderer(document: model.parser.document)
            case "transcriptkit-stream":
                TranscriptKitStreamRenderer(stream: model.stream)
            case "transcriptkit-uikit":
                TranscriptKitUIKitRenderer(stream: model.stream)
            case "none":
                Color.clear
            case "webview":
                WebRendererView(renderer: model.web)
            case "textual-noselect":
                TextualRenderer(history: model.history, current: model.current, selectable: false)
            default:
                TextualRenderer(history: model.history, current: model.current, selectable: true)
            }
        }
        .task { await model.run() }
    }
}
