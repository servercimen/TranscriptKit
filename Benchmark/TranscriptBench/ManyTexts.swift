import SwiftUI
@_spi(Diagnostics) import TranscriptKit

/// `-mode many`: a page of many texts that all get a new long document in the
/// same main-thread turn, while a stream at the top of the page gets a short
/// chunk. Each round prints one `MANY_RESULT {json}` line, then the app exits.
///
/// Launch arguments:
///   -views <n>     texts on the page (default 20)
///   -chars <n>     length of each new document (default 6000)
///   -rounds <n>    rounds, each with new documents (default 5)
@MainActor
@Observable
final class ManyTextsModel {
    private(set) var documents: [TranscriptDocument]
    @ObservationIgnored let stream = TranscriptStream(markdown: "The stream at the top of the page.")
    @ObservationIgnored private let views: Int
    @ObservationIgnored private let characters: Int
    @ObservationIgnored private let rounds: Int

    init() {
        let defaults = UserDefaults.standard
        views = defaults.object(forKey: "views") != nil ? max(defaults.integer(forKey: "views"), 1) : 20
        characters = defaults.object(forKey: "chars") != nil ? defaults.integer(forKey: "chars") : 6000
        rounds = defaults.object(forKey: "rounds") != nil ? max(defaults.integer(forKey: "rounds"), 1) : 5
        documents = (0..<views).map { MarkdownStreamParser.document(from: "Text \($0).", idPrefix: "start\($0)") }
    }

    func run() async {
        try? await Task.sleep(for: .seconds(2))
        for round in 1...rounds {
            await measure(round: round)
            try? await Task.sleep(for: .seconds(1))
        }
        if !UserDefaults.standard.bool(forKey: "hold") { exit(0) }
    }

    /// One round. The new documents are parsed before the round starts, so
    /// that the round measures layout only.
    private func measure(round: Int) async {
        let next = (0..<views).map { index in
            let markdown = String(Corpus.response(characters: characters, startingAt: round * 1000 + index * 10))
            return MarkdownStreamParser.document(from: markdown, idPrefix: "r\(round)v\(index)")
        }
        let threadsBefore = ThreadSampler.count()
        let sampler = ThreadSampler()
        sampler.start()
        let monitor = FrameMonitor()
        monitor.start()
        TranscriptDiagnostics.reset()
        let streamBefore = stream.document

        let start = ContinuousClock.now
        documents = next
        stream.append(" Round \(round) adds **short** text.")
        var parseMs: Double?
        var allInstalledMs: Double?
        // The stream's view installs its update too.
        while parseMs == nil || allInstalledMs == nil, ContinuousClock.now - start < .seconds(20) {
            try? await Task.sleep(for: .milliseconds(1))
            let elapsed = (ContinuousClock.now - start).milliseconds
            if parseMs == nil, stream.document != streamBefore { parseMs = elapsed }
            if allInstalledMs == nil, TranscriptDiagnostics.current.installs >= views + 1 { allInstalledMs = elapsed }
        }
        try? await Task.sleep(for: .milliseconds(500))
        let frames = monitor.stop()
        let threadsPeak = sampler.stop()

        let result = ManyResult(
            round: round, views: views, characters: characters, cores: ProcessInfo.processInfo.activeProcessorCount,
            threadsBefore: threadsBefore, threadsPeak: threadsPeak, streamParseMs: parseMs, allInstalledMs: allInstalledMs,
            installs: TranscriptDiagnostics.current.installs, worstFrameMs: frames.worstFrameMs,
            droppedFrames: frames.droppedFrames, osVersion: UIDevice.current.systemVersion
        )
        let json = String(data: try! JSONEncoder().encode(result), encoding: .utf8)!
        print("MANY_RESULT \(json)")
        fflush(stdout)
    }
}

struct ManyResult: Codable {
    var round: Int
    var views: Int
    var characters: Int
    var cores: Int
    /// Threads of the process before the round, and the most during it.
    var threadsBefore: Int
    var threadsPeak: Int
    /// From the new documents to the stream's parse of the short chunk on
    /// the main thread. It includes the wait for the next display frame.
    var streamParseMs: Double?
    /// From the new documents until every text has installed a layout.
    var allInstalledMs: Double?
    var installs: Int
    /// The longest main-thread frame of the round.
    var worstFrameMs: Double
    var droppedFrames: Int
    var osVersion: String
}

/// Samples the thread count of the process every 2 ms, on a thread of its
/// own, and keeps the highest.
final class ThreadSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak = 0
    private var running = true

    func start() {
        let thread = Thread { [self] in
            while lock.withLock({ running }) {
                let count = Self.count()
                lock.withLock { peak = max(peak, count) }
                usleep(2000)
            }
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() -> Int {
        lock.withLock {
            running = false
            return peak
        }
    }

    static func count() -> Int {
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else { return 0 }
        for index in 0..<Int(count) { mach_port_deallocate(mach_task_self_, threads[index]) }
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)),
                      vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        return Int(count)
    }
}

private extension Duration {
    var milliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}

struct ManyTextsRenderer: View {
    @State private var model = ManyTextsModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                TranscriptText(stream: model.stream)
                ForEach(model.documents.indices, id: \.self) { index in
                    TranscriptText(model.documents[index])
                }
            }
            .padding(16)
        }
        .task { await model.run() }
    }
}
