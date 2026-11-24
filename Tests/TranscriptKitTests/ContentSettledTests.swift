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
    try? await Task.sleep(for: .milliseconds(50))
    // Laid out, and waiting in the mailbox.
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
    try? await Task.sleep(for: .milliseconds(50))
    #expect(!work.isIdle)
    work.end()
    #expect(work.isIdle)
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
