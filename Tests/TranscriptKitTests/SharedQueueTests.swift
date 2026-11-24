import Foundation
import Testing
@testable import TranscriptKit

/// Counts the work items that run at the same time, and the threads they run on.
private final class Meter: @unchecked Sendable {
    private let lock = NSLock()
    private var running = 0
    private var maximum = 0
    private var seen: Set<UInt64> = []

    var peak: Int { lock.withLock { maximum } }
    var threads: Int { lock.withLock { seen.count } }

    func enter() {
        lock.withLock {
            running += 1
            maximum = max(maximum, running)
        }
        mark()
    }

    func leave() {
        lock.withLock { running -= 1 }
    }

    func mark() {
        var id: UInt64 = 0
        pthread_threadid_np(nil, &id)
        _ = lock.withLock { seen.insert(id) }
    }
}

/// The threads of this process. Other tests that run at the same time add theirs.
private func processThreadCount() -> Int {
    var threads: thread_act_array_t?
    var count: mach_msg_type_number_t = 0
    guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else { return 0 }
    for index in 0..<Int(count) { mach_port_deallocate(mach_task_self_, threads[index]) }
    vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
    return Int(count)
}

private struct Measurement: CustomStringConvertible {
    var queues: Int
    /// Nil when the work does not mark where it starts and ends.
    var peak: Int?
    var threads: Int
    var processThreadsBefore: Int
    var processThreadsPeak: Int

    var description: String {
        "\(queues) queues on \(cores) cores: " + (peak.map { "at most \($0) at once, " } ?? "")
            + "on \(threads) threads; "
            + "process threads \(processThreadsBefore) before, \(processThreadsPeak) at most"
    }
}

/// Suspends the queues, lets `enqueue` add work to each, and starts them all
/// at the same moment. `enqueue` gets the queue's index, and a closure to
/// call when its work is done.
private func measure(_ queues: [DispatchQueue], meter: Meter = Meter(),
                     enqueue: (Int, @escaping @Sendable () -> Void) -> Void) -> Measurement {
    let group = DispatchGroup()
    let before = processThreadCount()
    for queue in queues { queue.suspend() }
    for index in queues.indices {
        group.enter()
        enqueue(index) { group.leave() }
    }
    for queue in queues { queue.resume() }
    var peakThreads = before
    while group.wait(timeout: .now() + .milliseconds(2)) == .timedOut {
        peakThreads = max(peakThreads, processThreadCount())
    }
    return Measurement(queues: queues.count, peak: meter.peak > 0 ? meter.peak : nil, threads: meter.threads,
                       processThreadsBefore: before, processThreadsPeak: peakThreads)
}

private func markdown(paragraphs: Int) -> String {
    (0..<paragraphs).map { index in
        "Paragraph \(index) has **bold**, *italic* and `code` text that wraps over several lines at a narrow width, "
            + "so that laying it out takes a while."
    }.joined(separator: "\n\n")
}

private let longMarkdown = markdown(paragraphs: 800)
private let longDocument = MarkdownStreamParser.document(from: longMarkdown, idPrefix: "long")

private var cores: Int { ProcessInfo.processInfo.activeProcessorCount }

/// More queues than this run at once only if the queues get a thread each.
/// GCD adds a few threads to the pool when a thread waits, as Core Text
/// sometimes does.
private var bound: Int { cores + max(4, cores / 2) }

/// Enough queues to make the bound show on any machine.
private var manyQueues: Int { max(20, 3 * cores) }

/// Engines with a width and a long document each, as on a screen that
/// replaces its documents at once.
private func engines(_ count: Int) -> [LayoutEngine] {
    let engines = (0..<count).map { _ in LayoutEngine() }
    for engine in engines { _ = engine.relayout(width: 200, style: TranscriptStyle()) }
    return engines
}

private func timeOneLongLayout() -> TimeInterval {
    let start = Date()
    _ = DocumentLayout(document: longDocument, width: 200)
    return Date().timeIntervalSince(start)
}

@Suite(.serialized)
struct SharedQueueTests {
    init() {
        // Core Text loads its fonts the first time, and threads that wait for
        // that make GCD add threads.
        _ = timeOneLongLayout()
    }

    /// The engines lay out through their own code path. The output handler
    /// runs on the thread that made each layout.
    @Test(arguments: [20, manyQueues])
    func enginesThatLayOutAtOnceShareThePool(_ count: Int) {
        let engines = engines(count)
        let meter = Meter()
        let result = measure(engines.map(\.queue), meter: meter) { index, done in
            engines[index].setOutputHandler {
                meter.mark()
                done()
            }
            engines[index].submit(.init(document: longDocument, source: 1, sequence: 1))
        }
        print("Layout engines: \(result)")
        for engine in engines { #expect(engine.backgroundLayoutCount == 1) }
    }

    @Test func layoutsOnManyEngineQueuesRunAboutOnePerCore() throws {
        let engines = engines(manyQueues)
        let meter = Meter()
        let result = measure(engines.map(\.queue), meter: meter) { index, done in
            engines[index].queue.async {
                meter.enter()
                _ = DocumentLayout(document: longDocument, width: 200)
                meter.leave()
                done()
            }
        }
        print("Layouts on engine queues: \(result)")
        #expect(try #require(result.peak) <= bound)
    }

    @Test func manyStreamsParseAboutOnePerCore() throws {
        let workers = (0..<manyQueues).map { _ in StreamWorker(parser: MarkdownStreamParser()) }
        let meter = Meter()
        let result = measure(workers.map(\.queue), meter: meter) { index, done in
            let worker = workers[index]
            worker.queue.async {
                meter.enter()
                _ = worker.apply(longMarkdown, finish: true)
                meter.leave()
                done()
            }
        }
        print("Stream workers: \(result)")
        for worker in workers { #expect(worker.latest.isFinished) }
        #expect(try #require(result.peak) <= bound)
    }

    /// The main thread needs a layout now, as when the view gets a new width,
    /// from an engine that has a short layout waiting for a thread while
    /// every thread of the pool is busy.
    @Test func aSynchronousLayoutDoesNotWaitForTheBusyPool() throws {
        let busy = engines(manyQueues)
        let oneLongLayout = timeOneLongLayout()
        let engine = LayoutEngine()
        _ = engine.relayout(width: 200, style: TranscriptStyle())
        for engine in busy { engine.submit(.init(document: longDocument, source: 1, sequence: 1)) }
        Thread.sleep(forTimeInterval: 0.02)

        engine.submit(.init(document: MarkdownStreamParser.document(from: "Short text."), source: 1, sequence: 1))
        var start = Date()
        let result = try #require(engine.relayout(width: 180, style: TranscriptStyle()))
        let relayout = Date().timeIntervalSince(start)
        engine.submit(.init(document: MarkdownStreamParser.document(from: "Short text, longer."), source: 1, sequence: 2))
        start = Date()
        let height = engine.measure(width: 150, style: TranscriptStyle())
        let measure = Date().timeIntervalSince(start)
        print("While \(busy.count) engines lay out: relayout \(relayout * 1000) ms, measure \(measure * 1000) ms; "
              + "one long layout alone \(oneLongLayout * 1000) ms")
        #expect(result.layout.height > 0)
        #expect(height > 0)
        #expect(relayout < oneLongLayout)
        #expect(measure < oneLongLayout)
        for engine in busy { _ = engine.backgroundLayoutCount }
    }

    /// `TranscriptStream.flush()` calls `sync` on the stream's queue, which
    /// has a parse waiting for a thread while every thread of the pool is busy.
    @Test func aFlushDoesNotWaitForTheBusyPool() {
        let busy = engines(manyQueues)
        let oneLongLayout = timeOneLongLayout()
        let worker = StreamWorker(parser: MarkdownStreamParser())
        for engine in busy { engine.submit(.init(document: longDocument, source: 1, sequence: 1)) }
        Thread.sleep(forTimeInterval: 0.02)

        worker.queue.async { _ = worker.apply("Some **text", finish: false) }
        let start = Date()
        let latest = worker.queue.sync {
            _ = worker.apply("** here.", finish: true)
            return worker.latest
        }
        let elapsed = Date().timeIntervalSince(start)
        print("While \(busy.count) engines lay out: flush \(elapsed * 1000) ms; one long layout alone \(oneLongLayout * 1000) ms")
        #expect(latest.isFinished)
        #expect(latest.document.block(at: 0).text == "Some text here.")
        #expect(elapsed < oneLongLayout)
        for engine in busy { _ = engine.backgroundLayoutCount }
    }
}
