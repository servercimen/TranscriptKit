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
/// Long enough that the work of many queues overlaps, for the bound tests.
private let mediumMarkdown = markdown(paragraphs: 300)
private let mediumDocument = MarkdownStreamParser.document(from: mediumMarkdown, idPrefix: "medium")
private let shortDocument = MarkdownStreamParser.document(from: "Short text.", idPrefix: "short")

private var cores: Int { ProcessInfo.processInfo.activeProcessorCount }

/// More queues than this run at once only if the queues get a thread each.
/// GCD adds threads to the pool when a thread waits, as Core Text sometimes
/// does, so a single burst can go above it.
private var bound: Int { cores + max(4, cores / 2) }

/// Enough queues to make the bound show on any machine.
private var manyQueues: Int { max(20, 3 * cores) }

/// Engines with a width, as on a screen that shows many texts.
private func engines(_ count: Int) -> [LayoutEngine] {
    let engines = (0..<count).map { _ in LayoutEngine() }
    for engine in engines { _ = engine.relayout(width: 200, style: TranscriptStyle()) }
    return engines
}

/// Runs `measurement` a few times, and returns the run with the lowest
/// `value`. One run can go above the bound, but not every run.
private func fewest(_ value: (Measurement) -> Int, _ measurement: () -> Measurement) throws -> Measurement {
    let runs = (0..<5).map { _ in measurement() }
    let fewest = try #require(runs.min { value($0) < value($1) })
    print("Runs: \(runs.map(value)); fewest: \(fewest)")
    return fewest
}

/// Gives every engine a long document to lay out in the background. Returns
/// a closure that waits until all of them are done, and returns how long they took.
private func startLongLayouts(on engines: [LayoutEngine]) -> () -> TimeInterval {
    let group = DispatchGroup()
    for engine in engines {
        group.enter()
        engine.setOutputHandler { group.leave() }
    }
    let start = Date()
    for engine in engines { engine.submit(.init(document: longDocument, source: 1, sequence: 1)) }
    return {
        group.wait()
        return Date().timeIntervalSince(start)
    }
}

/// Runs `body` on a thread outside the pool, at the QoS of the main thread.
private func onInteractiveThread<T: Sendable>(_ body: @escaping @Sendable () -> T) -> T {
    nonisolated(unsafe) var value: T?
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
        value = body()
        done.signal()
    }
    thread.qualityOfService = .userInteractive
    thread.start()
    done.wait()
    return value!
}

@Suite(.serialized)
struct SharedQueueTests {
    init() {
        // Core Text loads its fonts the first time, and threads that wait for
        // that make GCD add threads.
        _ = DocumentLayout(document: longDocument, width: 200)
        _ = DocumentLayout(document: mediumDocument, width: 200)
    }

    /// A measurement: the engines lay out through their own code path, and
    /// the output handler runs on the thread that made each layout.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRANSCRIPTKIT_TIMING"] != nil), arguments: [20, manyQueues])
    func measureThreadsWhileEnginesLayOutAtOnce(_ count: Int) {
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
        let result = try fewest({ $0.peak ?? 0 }) {
            let meter = Meter()
            return measure(engines.map(\.queue), meter: meter) { index, done in
                engines[index].queue.async {
                    meter.enter()
                    _ = DocumentLayout(document: mediumDocument, width: 200)
                    meter.leave()
                    done()
                }
            }
        }
        #expect(try #require(result.peak) <= bound)
    }

    @Test func manyStreamsParseAboutOnePerCore() throws {
        let result = try fewest({ $0.peak ?? 0 }) {
            let workers = (0..<manyQueues).map { _ in StreamWorker(parser: MarkdownStreamParser()) }
            let meter = Meter()
            let result = measure(workers.map(\.queue), meter: meter) { index, done in
                let worker = workers[index]
                worker.queue.async {
                    meter.enter()
                    _ = worker.apply(mediumMarkdown, finish: true)
                    meter.leave()
                    done()
                }
            }
            for worker in workers { #expect(worker.latest.isFinished) }
            return result
        }
        #expect(try #require(result.peak) <= bound)
    }

    /// Short layouts go ahead of long ones at a higher QoS. Many of them at
    /// once still share a pool of about one thread for each core.
    @Test func manyShortLayoutsRunOnAboutOneThreadPerCore() throws {
        let engines = engines(manyQueues)
        let result = try fewest(\.threads) {
            let meter = Meter()
            let sequence = Int(Date().timeIntervalSince1970 * 1000)
            return measure(engines.map(\.queue), meter: meter) { index, done in
                let engine = engines[index]
                engine.setOutputHandler {
                    meter.mark()
                    _ = engine.takeOutput()
                    done()
                }
                let document = MarkdownStreamParser.document(from: "Short text \(sequence).", idPrefix: "\(sequence)")
                engine.submit(.init(document: document, source: 1, sequence: sequence))
            }
        }
        #expect(result.threads <= bound)
    }

    /// While every thread of the pool is busy with long layouts, short work
    /// that a person waits to see starts at once: the parse of a streamed
    /// chunk, a short document on another view, and text added to the end of
    /// a long document on a third view.
    @Test func shortWorkDoesNotWaitForTheBusyPool() throws {
        let busy = engines(manyQueues)
        let worker = StreamWorker(parser: MarkdownStreamParser())
        let short = LayoutEngine()
        _ = short.relayout(width: 200, style: TranscriptStyle())
        var parser = MarkdownStreamParser()
        parser.append(longMarkdown)
        let growing = LayoutEngine()
        growing.submit(.init(document: parser.document, source: 1, sequence: 1))
        _ = growing.relayout(width: 200, style: TranscriptStyle())
        parser.append("\n\nMore text at the end.")
        let grown = parser.document

        let lock = NSLock()
        nonisolated(unsafe) var waits: [String: TimeInterval] = [:]
        let done = DispatchGroup()
        let record: @Sendable (String, Date) -> Void = { name, start in
            lock.withLock { waits[name] = Date().timeIntervalSince(start) }
            done.leave()
        }
        let waitForBusy = startLongLayouts(on: busy)
        Thread.sleep(forTimeInterval: 0.02)

        for _ in 0..<3 { done.enter() }
        let start = Date()
        worker.parse("Some **text** here.", finish: true) { _ in record("parse", start) }
        short.setOutputHandler { record("short layout", start) }
        short.submit(.init(document: shortDocument, source: 1, sequence: 1))
        growing.setOutputHandler { record("append layout", start) }
        growing.submit(.init(document: grown, source: 1, sequence: 2))
        done.wait()
        let busyTime = waitForBusy()

        let longest = try #require(waits.values.max())
        print("While \(busy.count) engines lay out for \(busyTime * 1000) ms: "
              + waits.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value * 1000) ms" }.joined(separator: ", "))
        #expect(waits.count == 3)
        #expect(worker.latest.isFinished)
        #expect(longest < busyTime / 10)
    }

    /// The main thread needs a layout now, as when the view gets a new width,
    /// from an engine that has work waiting for a thread while every thread
    /// of the pool is busy. The work is not urgent, so only the `sync` call
    /// can get it a thread at once.
    @Test func aSynchronousLayoutDoesNotWaitForTheBusyPool() throws {
        let busy = engines(manyQueues)
        let engine = LayoutEngine()
        engine.submit(.init(document: shortDocument, source: 1, sequence: 1))
        _ = engine.relayout(width: 200, style: TranscriptStyle())
        let waitForBusy = startLongLayouts(on: busy)
        Thread.sleep(forTimeInterval: 0.02)

        let (relayout, measure, height) = onInteractiveThread {
            engine.queue.async {}
            var start = Date()
            let layout = engine.relayout(width: 180, style: TranscriptStyle())
            let relayout = Date().timeIntervalSince(start)
            engine.queue.async {}
            start = Date()
            _ = engine.measure(width: 150, style: TranscriptStyle())
            return (relayout, Date().timeIntervalSince(start), layout?.layout.height ?? 0)
        }
        let busyTime = waitForBusy()
        print("While \(busy.count) engines lay out for \(busyTime * 1000) ms: relayout \(relayout * 1000) ms, "
              + "measure \(measure * 1000) ms")
        #expect(height > 0)
        #expect(relayout < busyTime / 4)
        #expect(measure < busyTime / 4)
    }

    /// `TranscriptStream.flush()` waits for the stream's queue, which has a
    /// parse waiting for a thread while every thread of the pool is busy.
    @Test func aFlushDoesNotWaitForTheBusyPool() {
        let busy = engines(manyQueues)
        let worker = StreamWorker(parser: MarkdownStreamParser())
        let waitForBusy = startLongLayouts(on: busy)
        Thread.sleep(forTimeInterval: 0.02)

        let (latest, elapsed) = onInteractiveThread {
            worker.queue.async { _ = worker.apply("Some **text", finish: false) }
            let start = Date()
            let latest = worker.applyNow("** here.", finish: true)
            return (latest, Date().timeIntervalSince(start))
        }
        let busyTime = waitForBusy()
        print("While \(busy.count) engines lay out for \(busyTime * 1000) ms: flush \(elapsed * 1000) ms")
        #expect(latest.isFinished)
        #expect(latest.document.block(at: 0).text == "Some text here.")
        #expect(elapsed < busyTime / 4)
    }
}
