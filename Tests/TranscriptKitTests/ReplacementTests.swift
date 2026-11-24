import CoreGraphics
import Foundation
import Testing
@testable import TranscriptKit

private let shortAnswer = """
    ## Summary

    The build runs in **two steps**: the first one compiles the package, and the second one runs the tests on \
    the device. Each step writes its log to the `build` folder.

    - Compile the package.
    - Run the tests, then read the log.

    If a step fails, run it again with `--verbose` and read the [guide](https://example.com/guide).
    """

private let otherAnswer = """
    ## Details

    A short text in a new layout: one heading, one paragraph that wraps onto a few lines at the width of a \
    phone, and a list.

    1. Open the settings.
    2. Turn on the option.
    3. Close the settings again, and check that the text changed.

    That is all.
    """

// MARK: Which path a document takes

@Test func aReplacedDocumentIsLaidOutNow() {
    let old = MarkdownStreamParser.document(from: shortAnswer)
    let new = MarkdownStreamParser.document(from: otherAnswer)
    #expect(DocumentUpdate.choose(replacing: old, with: new, isLaidOut: true, crossfade: 0.25) == .now(crossfade: 0.25))
    #expect(DocumentUpdate.choose(replacing: old, with: new, isLaidOut: true, crossfade: 0) == .now(crossfade: 0))
    #expect(DocumentUpdate.choose(replacing: old, with: new, isLaidOut: true, crossfade: -1) == .now(crossfade: 0))
    // Shorter text is a replacement too.
    let shorter = MarkdownStreamParser.document(from: String(shortAnswer.prefix(40)))
    #expect(DocumentUpdate.choose(replacing: old, with: shorter, isLaidOut: true, crossfade: 0.25) == .now(crossfade: 0.25))
}

@Test func anAppendStaysInTheBackground() {
    let old = MarkdownStreamParser.document(from: String(shortAnswer.prefix(120)))
    // The same text parsed again, longer: the same block ids, more text.
    let longer = MarkdownStreamParser.document(from: shortAnswer)
    #expect(longer.extends(old))
    #expect(DocumentUpdate.choose(replacing: old, with: longer, isLaidOut: true, crossfade: 0.25) == .background)

    var appended = TranscriptDocument(blocks: [TranscriptBlock(id: "a", text: "Some text")])
    let before = appended
    appended.appendToLastBlock(", and more")
    appended.append(TranscriptBlock(id: "b", text: "A new block"))
    #expect(DocumentUpdate.choose(replacing: before, with: appended, isLaidOut: true, crossfade: 0.25) == .background)
}

@Test func theOptionAndALayoutAreNeededToLayOutNow() {
    let old = MarkdownStreamParser.document(from: shortAnswer)
    let new = MarkdownStreamParser.document(from: otherAnswer)
    #expect(DocumentUpdate.choose(replacing: old, with: new, isLaidOut: true, crossfade: nil) == .background)
    #expect(DocumentUpdate.choose(replacing: old, with: new, isLaidOut: false, crossfade: 0.25) == .background)
    // The first text after an empty document adds to it.
    #expect(DocumentUpdate.choose(replacing: TranscriptDocument(), with: new, isLaidOut: true, crossfade: 0.25) == .background)
}

@Test func aPrefixWithOtherIDsIsAReplacement() {
    let summary = String(shortAnswer.prefix(120))
    // With the same ids, the full text only adds to its start.
    #expect(MarkdownStreamParser.document(from: shortAnswer).extends(MarkdownStreamParser.document(from: summary)))
    let old = MarkdownStreamParser.document(from: summary, idPrefix: "summary")
    let new = MarkdownStreamParser.document(from: shortAnswer, idPrefix: "details")
    #expect(DocumentUpdate.choose(replacing: old, with: new, isLaidOut: true, crossfade: 0.25) == .now(crossfade: 0.25))
    #expect(DocumentUpdate.choose(replacing: new, with: old, isLaidOut: true, crossfade: 0.25) == .now(crossfade: 0.25))
}

@Test func aBlockWithTheSameIDAndOtherTextIsAReplacement() {
    let old = TranscriptDocument(blocks: [TranscriptBlock(id: "a", text: "First answer")])
    let new = TranscriptDocument(blocks: [TranscriptBlock(id: "a", text: "Second answer")])
    #expect(DocumentUpdate.choose(replacing: old, with: new, isLaidOut: true, crossfade: 0.25) == .now(crossfade: 0.25))
}

// MARK: The engine

/// An engine that shows `document`, as a view with a layout does.
private func engineShowing(_ document: TranscriptDocument, width: CGFloat = 375) -> (LayoutEngine, DocumentLayout) {
    let engine = LayoutEngine()
    _ = engine.relayout(width: width, style: .init())
    engine.submit(.init(document: document, source: 0, sequence: 1, isFinished: true), schedulesLayout: false)
    let shown = engine.relayout(width: width, style: .init())!.layout
    return (engine, shown)
}

@Test func aReplacementIsLaidOutOnceOnTheCallingThread() {
    let old = MarkdownStreamParser.document(from: shortAnswer)
    let new = MarkdownStreamParser.document(from: otherAnswer + "\n\nOne more paragraph, so the new text is taller.")
    let (engine, shown) = engineShowing(old)
    engine.submit(.init(document: new, source: 0, sequence: 2, isFinished: true), schedulesLayout: false)
    let result = engine.relayout(width: 375, style: .init())
    #expect(result?.layout.document == new)
    #expect(result?.isFinished == true)
    // The blocks have the ids of the old ones; none of the old lines stay.
    let fresh = DocumentLayout(document: new, width: 375)
    #expect(result?.layout.height == fresh.height)
    #expect(result?.layout.height != shown.height)
    #expect(engine.measure(width: 375, style: .init()) == fresh.height)
    // The queue does not lay it out again, and nothing older comes after it.
    engine.drainNow()
    #expect(engine.takeOutput() == nil)
    #expect(engine.backgroundLayoutCount == 0)
}

@Test func aDrainThatIsAlreadyScheduledLeavesAReplacementToTheCallingThread() {
    let (engine, _) = engineShowing(MarkdownStreamParser.document(from: shortAnswer))
    let queued = MarkdownStreamParser.document(from: shortAnswer + "\n\nMore text.")
    let new = MarkdownStreamParser.document(from: otherAnswer)
    // Holds the queue, so the drain that the first request schedules runs
    // after the replacement is submitted.
    let gate = DispatchSemaphore(value: 0)
    engine.queue.async { gate.wait() }
    engine.submit(.init(document: queued, source: 0, sequence: 2, isFinished: true))
    engine.submit(.init(document: new, source: 0, sequence: 3, isFinished: true), schedulesLayout: false)
    gate.signal()
    let result = engine.relayout(width: 375, style: .init())
    #expect(result?.layout.document == new)
    engine.drainNow()
    #expect(engine.takeOutput() == nil)
    #expect(engine.backgroundLayoutCount == 0)
}

@Test func anAppendAfterAReplacementBuildsOnIt() {
    let (engine, _) = engineShowing(MarkdownStreamParser.document(from: shortAnswer))
    let new = MarkdownStreamParser.document(from: String(otherAnswer.prefix(80)))
    engine.submit(.init(document: new, source: 0, sequence: 2, isFinished: true), schedulesLayout: false)
    let replaced = engine.relayout(width: 375, style: .init())!.layout
    let longer = MarkdownStreamParser.document(from: otherAnswer)
    engine.submit(.init(document: longer, source: 0, sequence: 3, isFinished: true))
    // The queue lays it out: `backgroundLayoutCount` waits for it.
    #expect(engine.backgroundLayoutCount == 1)
    let output = engine.takeOutput()
    #expect(output?.layout.document == longer)
    #expect(output?.base === replaced)
    #expect(output?.isAppend == true)
}

// Times what the view does on the main thread for a replaced document, for a
// short text: the engine call that the document setter makes. Opt in, in release:
//   TRANSCRIPTKIT_TIMING=1 swift test -c release --filter replacementTiming
@Test(.enabled(if: ProcessInfo.processInfo.environment["TRANSCRIPTKIT_TIMING"] != nil))
func replacementTiming() {
    // Each document is new text, so no line of the one before is reused.
    let documents = (0..<200).map { index in
        MarkdownStreamParser.document(from: (index.isMultiple(of: 2) ? shortAnswer : otherAnswer) + "\n\nAnswer \(index).")
    }
    print("TIMING replacement text: \(documents[0].utf16Count) UTF-16 units, \(documents[0].count) blocks")
    for width: CGFloat in [375, 320] {
        let (engine, _) = engineShowing(documents[0], width: width)
        var times: [Double] = []
        for (index, document) in documents.enumerated().dropFirst() {
            let start = DispatchTime.now().uptimeNanoseconds
            engine.submit(.init(document: document, source: 0, sequence: index + 1, isFinished: true), schedulesLayout: false)
            _ = engine.relayout(width: width, style: .init())
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e3)
        }
        times.sort()
        let median = times[times.count / 2]
        let p90 = times[times.count * 9 / 10]
        print("TIMING replacement at \(Int(width)) pt: median \(String(format: "%.0f", median)) µs, "
              + "90th percentile \(String(format: "%.0f", p90)) µs, best \(String(format: "%.0f", times[0])) µs")
    }
}
