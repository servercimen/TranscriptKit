import CoreGraphics
import Foundation
import Testing
@testable import TranscriptKit

/// Holds back async work until the test opens it.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let open = lock.withLock {
                if !isOpen { waiting.append(continuation) }
                return isOpen
            }
            if open { continuation.resume() }
        }
    }

    func open() {
        let resumed = lock.withLock {
            isOpen = true
            defer { waiting = [] }
            return waiting
        }
        resumed.forEach { $0.resume() }
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func raise() { lock.withLock { count += 1 } }
    var raised: Int { lock.withLock { count } }
}

/// Waits until `condition` holds, for at most two seconds.
private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<200 where !condition() {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

private let image = TranscriptImage(source: "https://x.y/c.png", alt: "a chart")

@Test func pendingWorkCallsItsHandlerWhenTheLastPieceEnds() {
    let work = PendingWork()
    let idle = Flag()
    work.setOnIdle { idle.raise() }
    #expect(work.isIdle)
    work.begin()
    work.begin()
    work.end()
    #expect(!work.isIdle)
    #expect(idle.raised == 0)
    work.end()
    #expect(work.isIdle)
    #expect(idle.raised == 1)
}

@Test func aLayoutIsPendingUntilTheViewTakesIt() async {
    let engine = LayoutEngine()
    let posted = Flag()
    engine.setOutputHandler { posted.raise() }
    _ = engine.relayout(width: 300, style: TranscriptStyle())
    #expect(engine.work.isIdle)

    engine.submit(.init(document: MarkdownStreamParser.document(from: "Some text"), source: 1, sequence: 1))
    #expect(!engine.work.isIdle)
    await waitUntil { posted.raised > 0 }
    // Laid out, and waiting in the mailbox until the test takes it.
    #expect(!engine.work.isIdle)

    #expect(engine.takeOutput() != nil)
    await waitUntil { engine.work.isIdle }
    #expect(engine.work.isIdle)
}

@Test func aRequestThatLaysOutNothingEndsItsWork() async {
    let engine = LayoutEngine()
    // No width yet: the drain keeps the document and posts nothing.
    engine.submit(.init(document: MarkdownStreamParser.document(from: "Some text"), source: 1, sequence: 1))
    await waitUntil { engine.work.isIdle }
    #expect(engine.work.isIdle)
    #expect(engine.takeOutput() == nil)
}

@Test func aPictureThatDoesNotLoadStillEndsItsWork() async {
    let store = TranscriptImageStore()
    let gate = Gate()
    let changes = Flag()
    store.setLoader({ _ in
        await gate.wait()
        return nil
    }, onChange: { changes.raise() })
    #expect(store.picture(for: image) == nil)
    #expect(!store.work.isIdle)
    gate.open()
    await waitUntil { store.work.isIdle }
    #expect(store.work.isIdle)
    #expect(changes.raised == 0)
}

@Test func workThatAChangeStartsKeepsTheStoreBusy() async {
    let store = TranscriptImageStore()
    let work = store.work
    let changes = Flag()
    store.setLoader({ _ in
        CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
    }, onChange: {
        // As the view does: the relayout on main is work too.
        work.begin()
        changes.raise()
    })
    _ = store.picture(for: image)
    await waitUntil { changes.raised > 0 }
    // Busy until the test ends the work that the change began.
    #expect(!work.isIdle)
    work.end()
    #expect(work.isIdle)
}

@Test func settlingFadesIsPendingWork() async {
    let engine = LayoutEngine()
    let release = DispatchSemaphore(value: 0)
    engine.queue.async { release.wait() }
    engine.settleFinishedFades()
    #expect(!engine.work.isIdle)
    release.signal()
    await waitUntil { engine.work.isIdle }
    #expect(engine.work.isIdle)
}

@Test func formulasAndCodeColorsArePendingUntilTheyArrive() async {
    let store = TranscriptImageStore()
    let gate = Gate()
    store.setMathRenderer { _, _ in
        await gate.wait()
        return nil
    }
    store.setHighlighter { code, _ in
        await gate.wait()
        return [TranscriptCodeHighlight(range: 0..<min(code.utf16.count, 3), color: TranscriptColor(red: 1, green: 0, blue: 0))]
    }
    _ = store.formula(for: TranscriptMath(tex: "x^2", isDisplay: false), fontSize: 17)
    _ = store.highlights(for: "b", text: "let", language: nil)
    // Waits for the first text's colors, then is highlighted too.
    _ = store.highlights(for: "b", text: "let a", language: nil)
    #expect(!store.work.isIdle)
    gate.open()
    await waitUntil { store.work.isIdle }
    #expect(store.work.isIdle)
    #expect(!store.highlights(for: "b", text: "let a", language: nil).isEmpty)
    #expect(store.work.isIdle)
}

// MARK: Waiting for the content to settle

/// A layout engine wired as `TranscriptTextView` wires it, without UIKit:
/// results install on main, and a picture's arrival lays out again on main.
@MainActor
private final class Host {
    let engine = LayoutEngine()
    let waiters: ContentSettledWaiters
    private(set) var stream: TranscriptStream?
    private(set) var installed: DocumentLayout?
    private(set) var draws = 0
    var width: CGFloat
    private var source = 0

    init(width: CGFloat = 300) {
        self.width = width
        waiters = ContentSettledWaiters(work: engine.work)
        engine.setOutputHandler { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.install() }
            }
        }
        waiters.stream = { [weak self] in self?.stream }
        waiters.draw = { [weak self] in self?.draws += 1 }
        relayout()
    }

    var text: String {
        guard let installed else { return "" }
        return installed.document.text(in: 0..<installed.length)
    }

    private func install() {
        if let output = engine.takeOutput() { installed = output.layout }
    }

    func relayout() {
        installed = engine.relayout(width: width, style: TranscriptStyle())?.layout
    }

    func setLoader(_ loader: @escaping @Sendable (TranscriptImage) async -> CGImage?) {
        let work = engine.work
        engine.images.setLoader(loader) { [weak self] in
            work.begin()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.relayout() }
                work.end()
            }
        }
    }

    func show(_ stream: TranscriptStream) {
        self.stream = stream
        source += 1
        let source = source
        let engine = engine
        let attachment = stream.attachSink { update in
            engine.submit(.init(document: update.document, source: source, sequence: update.sequence, isFinished: update.isFinished))
        }
        engine.submit(.init(document: attachment.latest.document, source: source, sequence: attachment.latest.sequence,
                            isFinished: attachment.latest.isFinished))
    }
}

/// Waits on main until `condition` holds, for at most two seconds.
@MainActor
private func waitOnMain(_ condition: () -> Bool) async {
    for _ in 0..<200 where !condition() {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

private func picture() -> CGImage? {
    CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
}

@MainActor
@Test(.timeLimit(.minutes(1))) func contentWithNothingPendingSettlesAtOnce() async {
    let host = Host()
    await host.waiters.wait()
    #expect(host.draws == 1)
    #expect(host.waiters.count == 0)
}

@MainActor
@Test(.timeLimit(.minutes(1))) func contentSettlesOnceTheStreamAndThePicturesAreIn() async throws {
    let host = Host()
    let gate = Gate()
    host.setLoader { _ in
        await gate.wait()
        return picture()
    }
    let stream = TranscriptStream()
    host.show(stream)
    stream.append("see ![a chart](https://x.y/c.png) here")
    stream.finish()

    var settled = false
    let waiting = Task { @MainActor in
        await host.waiters.wait()
        settled = true
    }
    await waitOnMain { host.text.hasPrefix("see") }
    try await Task.sleep(for: .milliseconds(100))
    #expect(!settled)
    #expect(host.draws == 0)
    #expect(try #require(host.installed).entry(at: 0).layout.attachments.first?.attachment.picture == nil)

    gate.open()
    await waiting.value
    #expect(settled)
    #expect(host.draws == 1)
    #expect(host.engine.work.isIdle)
    #expect(stream.isIdle)
    #expect(try #require(host.installed).entry(at: 0).layout.attachments.first?.attachment.picture != nil)
}

@MainActor
@Test(.timeLimit(.minutes(1))) func anUnfinishedStreamSettlesBetweenItsChunks() async {
    let host = Host()
    let stream = TranscriptStream()
    host.show(stream)
    stream.append("One two")
    await host.waiters.wait()
    #expect(host.text == "One two")

    stream.append(" three")
    await host.waiters.wait()
    #expect(host.text == "One two three")

    // Text that the parser holds back makes no new version, and still settles.
    stream.append("\n\n#")
    await host.waiters.wait()
    #expect(stream.isIdle)
    #expect(host.text == "One two three")
}

@MainActor
@Test(.timeLimit(.minutes(1))) func aCancelledWaitReturnsAtOnce() async {
    let host = Host()
    let gate = Gate()
    host.setLoader { _ in
        await gate.wait()
        return nil
    }
    let stream = TranscriptStream()
    host.show(stream)
    stream.append("see ![a chart](https://x.y/c.png) here")
    stream.flush()
    await waitOnMain { host.text.hasPrefix("see") }

    let first = Task { @MainActor in await host.waiters.wait() }
    let second = Task { @MainActor in await host.waiters.wait() }
    await waitOnMain { host.waiters.count == 2 }
    first.cancel()
    await first.value
    #expect(host.waiters.count == 1)
    #expect(host.draws == 0)

    // Already cancelled: it does not wait at all.
    let third = Task { @MainActor in
        withUnsafeCurrentTask { $0?.cancel() }
        await host.waiters.wait()
    }
    await third.value
    #expect(host.waiters.count == 1)

    // The image loads nothing, and that counts as done.
    gate.open()
    await second.value
    #expect(host.waiters.count == 0)
    #expect(host.draws == 1)
}

@MainActor
private final class FlushRecord {
    var waitersBefore = -1
    var drawsAfter = -1
}

@MainActor
@Test(.timeLimit(.minutes(1))) func aFlushDoesNotSettleInsideTheCall() async {
    let host = Host()
    let stream = TranscriptStream()
    host.show(stream)
    stream.append("One two")
    await host.waiters.wait()
    let draws = host.draws

    let flush = FlushRecord()
    // In the main queue before the append starts the frame timer, so the
    // frame cannot parse the text before the flush.
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            flush.waitersBefore = host.waiters.count
            stream.flush()
            flush.drawsAfter = host.draws
        }
    }
    // Text that the parser holds back starts no layout work.
    stream.append("\n\n#")
    await host.waiters.wait()
    #expect(flush.waitersBefore == 1)
    #expect(flush.drawsAfter == draws)
    #expect(host.draws == draws + 1)
}

@MainActor
@Test(.timeLimit(.minutes(1))) func workThatTheLayoutStartsHoldsTheWaitBack() async throws {
    let host = Host(width: 0)
    let gate = Gate()
    host.setLoader { _ in
        await gate.wait()
        return picture()
    }
    host.engine.submit(.init(document: MarkdownStreamParser.document(from: "see ![a chart](https://x.y/c.png) here"),
                             source: 1, sequence: 1, isFinished: true))
    // No width yet: the drain keeps the document and lays out nothing.
    await waitOnMain { host.engine.work.isIdle }
    #expect(host.installed == nil)

    // As a view does when it gets its width: the layout asks for the picture.
    host.waiters.layOut = { [weak host] in
        guard let host, host.width == 0 else { return }
        host.width = 300
        host.relayout()
    }
    var settled = false
    let waiting = Task { @MainActor in
        await host.waiters.wait()
        settled = true
    }
    await waitOnMain { host.installed != nil }
    try await Task.sleep(for: .milliseconds(100))
    #expect(!settled)
    #expect(host.draws == 0)
    #expect(try #require(host.installed).entry(at: 0).layout.attachments.first?.attachment.picture == nil)

    gate.open()
    await waiting.value
    #expect(host.draws == 1)
    #expect(try #require(host.installed).entry(at: 0).layout.attachments.first?.attachment.picture != nil)
}

@MainActor
@Test(.timeLimit(.minutes(1))) func aStreamThatChangesWhileATaskWaitsSettlesOnTheNewStream() async {
    let host = Host()
    let gate = Gate()
    host.setLoader { _ in
        await gate.wait()
        return nil
    }
    let first = TranscriptStream()
    host.show(first)
    first.append("see ![a chart](https://x.y/c.png) here")
    first.flush()
    await waitOnMain { host.text.hasPrefix("see") }

    let waiting = Task { @MainActor in await host.waiters.wait() }
    await waitOnMain { host.waiters.count == 1 }
    let second = TranscriptStream()
    host.show(second)
    second.append("Other text")
    gate.open()
    await waiting.value
    #expect(second.isIdle)
    #expect(host.text == "Other text")
}
