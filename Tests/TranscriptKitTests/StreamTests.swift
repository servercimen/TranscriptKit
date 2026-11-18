import Foundation
import Testing
@testable import TranscriptKit

/// Collects what a stream sends to a sink, from whatever thread it runs on.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [StreamUpdate] = []
    private var threads: [Bool] = []

    var updates: [StreamUpdate] { lock.withLock { stored } }
    var ranOnMainThread: [Bool] { lock.withLock { threads } }

    func record(_ update: StreamUpdate) -> Bool {
        lock.withLock {
            stored.append(update)
            threads.append(Thread.isMainThread)
        }
        return true
    }
}

@MainActor
@Test func appendedTextWaitsForTheNextFrame() {
    let stream = TranscriptStream()
    stream.append("Hello **wor")
    stream.append("ld** and more")
    #expect(stream.document.count == 0)

    stream.flush()
    #expect(content(stream.document) == content(MarkdownStreamParser.document(from: "Hello **world** and more")))
    #expect(stream.document.block(at: 0).text == "Hello world and more")
}

@MainActor
@Test func sinksGetOneUpdatePerParse() {
    let stream = TranscriptStream(markdown: "# Title\n\n")
    let recorder = Recorder()
    let attachment = stream.attachSink { recorder.record($0) }
    // Attaching returns the current document.
    #expect(attachment.latest.document.count == 1)
    #expect(recorder.updates.isEmpty)

    for chunk in ["Some ", "text ", "in ", "pieces"] { stream.append(chunk) }
    stream.flush()
    #expect(recorder.updates.count == 1)
    #expect(recorder.updates[0].sequence > attachment.latest.sequence)
    #expect(recorder.updates[0].document.block(at: 1).text == "Some text in pieces")

    // Nothing pending: no update.
    stream.flush()
    #expect(recorder.updates.count == 1)

    // Text that is held back (a possible heading marker) changes nothing visible.
    stream.append("\n\n#")
    stream.flush()
    #expect(recorder.updates.count == 1)

    stream.detachSink(attachment.id)
    stream.append(" More")
    stream.flush()
    #expect(recorder.updates.count == 1)
}

@MainActor
@Test func sinksThatAreDoneAreDropped() {
    let stream = TranscriptStream()
    let calls = Recorder()
    _ = stream.attachSink { update in
        _ = calls.record(update)
        return false
    }
    stream.append("one")
    stream.flush()
    stream.append(" two")
    stream.flush()
    #expect(calls.updates.count == 1)
}

@MainActor
@Test func finishingCanRewriteTheTail() {
    let stream = TranscriptStream()
    stream.append("Price is 5 *")
    stream.flush()
    let streamed = stream.document
    #expect(streamed.block(at: 0).text == "Price is 5 ")

    // The held-back "*" turns out to be literal text: still an append.
    stream.finish()
    stream.flush()
    #expect(stream.document.block(at: 0).text == "Price is 5 *")
    #expect(stream.document.extends(streamed))

    // Unclosed emphasis was shown styled while streaming; at the end the
    // markers reappear as text, which rewrites what was shown.
    let other = TranscriptStream()
    other.append("an *open emphasis")
    other.flush()
    let open = other.document
    #expect(open.block(at: 0).text == "an open emphasis")
    other.finish()
    other.flush()
    #expect(other.document.block(at: 0).text == "an *open emphasis")
    #expect(!other.document.extends(open))
}

/// Without `flush()`, appended text still arrives, including the last chunk
/// when it is appended while a parse is running.
@MainActor
@Test func streamedTextArrivesOnItsOwn() async throws {
    let stream = TranscriptStream()
    let recorder = Recorder()
    _ = stream.attachSink { recorder.record($0) }
    let text = (1...40).map { "Line \($0) with **bold** text.\n\n" }.joined()
    for character in text {
        stream.append(String(character))
        if Int.random(in: 0..<20) == 0 { try await Task.sleep(for: .milliseconds(1)) }
    }
    stream.finish()
    for _ in 0..<200 where content(stream.document) != content(MarkdownStreamParser.document(from: text)) {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(content(stream.document) == content(MarkdownStreamParser.document(from: text)))
    // Parsed in the background, in order.
    #expect(!recorder.updates.isEmpty)
    #expect(recorder.ranOnMainThread.allSatisfy { !$0 })
    #expect(recorder.updates.map(\.sequence) == recorder.updates.map(\.sequence).sorted())
}

@MainActor
@Test func streamingMatchesParsingInOneGo() {
    let markdown = """
    ## Heading

    A paragraph with **bold** and `code`.

    - one
    - two

    ```swift
    let x = 1
    ```

    Done.
    """
    let stream = TranscriptStream()
    var rest = Substring(markdown)
    var step = 0
    while !rest.isEmpty {
        let size = [1, 3, 7, 2][step % 4]
        stream.append(String(rest.prefix(size)))
        rest = rest.dropFirst(size)
        // Frames land at irregular points in the text.
        if step % 3 == 0 { stream.flush() }
        step += 1
    }
    stream.finish()
    stream.flush()
    #expect(content(stream.document) == content(MarkdownStreamParser.document(from: markdown)))
}

// MARK: Layout engine

@Test func layoutEngineInstallsTheNewestDocument() async throws {
    let engine = LayoutEngine()
    let delivered = Recorder()
    engine.setOutputHandler { _ = delivered.record(StreamUpdate(document: TranscriptDocument(), sequence: 0)) }
    // No width yet: nothing is laid out in the background.
    var parser = MarkdownStreamParser(idPrefix: "e")
    parser.append("First paragraph.\n\nSecond")
    engine.submit(.init(document: parser.document, source: 1, sequence: 1))
    let first = try #require(engine.relayout(width: 300, style: TranscriptStyle()))
    #expect(first.layout.document == parser.document)

    // Appends are laid out in the background against the installed layout.
    for (sequence, chunk) in [" paragraph", " grows", " longer and longer."].enumerated() {
        parser.append(chunk)
        engine.submit(.init(document: parser.document, source: 1, sequence: sequence + 2))
    }
    // Old sequence numbers and old sources are ignored.
    engine.submit(.init(document: TranscriptDocument(), source: 1, sequence: 2))
    engine.submit(.init(document: TranscriptDocument(), source: 0, sequence: 99))
    engine.drainNow()
    let output = try #require(engine.takeOutput())
    #expect(output.layout.document == parser.document)
    #expect(output.base === first.layout)
    #expect(output.isAppend)
    // The first block is unchanged, so only the second block's band changed.
    #expect(output.changedTop! >= first.layout.entry(at: 1).y)
    #expect(engine.takeOutput() == nil)
    #expect(delivered.updates.count >= 1)

    // A new source replaces the old one.
    engine.submit(.init(document: MarkdownStreamParser.document(from: "Other"), source: 2, sequence: 1))
    engine.drainNow()
    let replaced = try #require(engine.takeOutput())
    #expect(replaced.source == 2)
    #expect(!replaced.isAppend)
}

@Test func measuringKeepsTheLayoutForTheNextRelayout() throws {
    let engine = LayoutEngine()
    engine.submit(.init(document: MarkdownStreamParser.document(from: "Some text that wraps at narrow widths."), source: 1, sequence: 1))
    let height = engine.measure(width: 120, style: TranscriptStyle())
    let result = try #require(engine.relayout(width: 120, style: TranscriptStyle()))
    #expect(result.layout.height == height)
    #expect(result.layout.reusedBlockCount == 1)
}

/// Blocks without their ids, which depend on the parser instance.
private func content(_ document: TranscriptDocument) -> [String] {
    document.blocks.map { "\($0.kind)|\($0.text)|\($0.spans)" }
}

/// Documents that arrive faster than the display refreshes are merged: the
/// engine lays out at most one per frame, always the newest.
@Test func layoutEngineLaysOutAtMostOncePerFrame() async throws {
    let engine = LayoutEngine()
    engine.setFramesPerSecond(60)
    var parser = MarkdownStreamParser(idPrefix: "p")
    parser.append("Start")
    engine.submit(.init(document: parser.document, source: 1, sequence: 1))
    _ = try #require(engine.relayout(width: 300, style: TranscriptStyle()))

    let start = Date()
    let submissions = 150
    for sequence in 2..<(2 + submissions) {
        parser.append(" word")
        engine.submit(.init(document: parser.document, source: 1, sequence: sequence))
        try await Task.sleep(for: .milliseconds(1))
    }
    let elapsed = Date().timeIntervalSince(start)
    try await Task.sleep(for: .milliseconds(50))
    engine.drainNow()
    let output = try #require(engine.takeOutput())
    // The newest document was laid out...
    #expect(output.layout.document == parser.document)
    // ...in at most about one layout per 1/60 s of the time it took to
    // submit them (whatever the scheduler made of the 1 ms sleeps).
    let frames = Int((elapsed + 0.05) * 60) + 3
    #expect(engine.backgroundLayoutCount <= frames, "\(engine.backgroundLayoutCount) layouts in \(elapsed) s")
    #expect(engine.backgroundLayoutCount < submissions / 2)
}
