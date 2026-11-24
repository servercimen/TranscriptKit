import CoreGraphics
import Foundation
import Testing
@testable import TranscriptKit

@Test func leastRecentlyUsedRemovesTheOldestOverItsLimit() {
    var cache = LeastRecentlyUsed<String, Int>(costLimit: 30)
    cache.set(1, for: "a", cost: 10)
    cache.set(2, for: "b", cost: 10)
    cache.set(3, for: "c", cost: 10)
    // Using "a" makes "b" the oldest.
    #expect(cache.value(for: "a") == 1)
    cache.set(4, for: "d", cost: 10)
    #expect(!cache.contains("b"))
    #expect(cache.contains("a") && cache.contains("c") && cache.contains("d"))
    #expect(cache.totalCost == 30)
    // A new value for a key replaces its cost.
    cache.set(5, for: "c", cost: 20)
    #expect(cache.totalCost == 30)
    #expect(cache.count == 2)
    #expect(cache.value(for: "c") == 5)
    // The newest value stays, even when it alone is over the limit.
    cache.set(6, for: "e", cost: 50)
    #expect(cache.count == 1)
    #expect(cache.value(for: "e") == 6)
    cache.removeAll()
    #expect(cache.count == 0 && cache.totalCost == 0)
}

/// A drawn formula: an opaque box `width` by `height` pixels.
func solidFormula(width: Int, height: Int) -> TranscriptMathImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return TranscriptMathImage(image: context.makeImage()!, size: CGSize(width: width, height: height), baseline: 2)
}

/// Waits until `condition` holds, for at most two seconds.
func waitFor(_ condition: () -> Bool) async {
    for _ in 0..<200 where !condition() {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

extension TranscriptImageStore {
    /// The image given for `math` in `slot` (by default, a slot of its own), if any.
    func drawnImage(_ math: TranscriptMath, fontSize: CGFloat = 17, slot: String? = nil) -> TranscriptMathImage? {
        guard case .drawn(let image) = formula(for: math, fontSize: fontSize, in: MathSlot(block: slot ?? math.tex, index: 0)) else {
            return nil
        }
        return image
    }
}

/// Records which formulas a renderer was asked to draw.
final class RenderCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ tex: String) { lock.withLock { items.append(tex) } }
    var all: [String] { lock.withLock { items } }
}

@Test func storesThatShareACacheDrawAFormulaOnce() async {
    let cache = TranscriptMathCache()
    let calls = RenderCalls()
    let renderer: TranscriptMathRenderer = { math, _ in
        calls.add(math.tex)
        try? await Task.sleep(for: .milliseconds(50))
        return solidFormula(width: 20, height: 10)
    }
    let stores = (0..<3).map { _ in TranscriptImageStore(mathCache: cache) }
    let math = TranscriptMath(tex: "x^2", isDisplay: false)
    for store in stores {
        store.setMathRenderer(renderer)
        #expect(store.drawnImage(math) == nil)
    }
    await waitFor { stores.allSatisfy { $0.drawnImage(math) != nil } }
    #expect(stores.allSatisfy { $0.drawnImage(math) != nil })
    #expect(calls.all == ["x^2"])
    // A store that comes later finds it drawn.
    let later = TranscriptImageStore(mathCache: cache)
    later.setMathRenderer(renderer)
    #expect(later.drawnImage(math) != nil)
    // Another font size is another formula.
    #expect(later.drawnImage(math, fontSize: 20, slot: "larger") == nil)
    await waitFor { calls.all.count == 2 }
    #expect(cache.drawCount == 2)
}

@Test func aFormulaThatFailsIsNotDrawnAgain() async {
    let cache = TranscriptMathCache()
    let store = TranscriptImageStore(mathCache: cache)
    let calls = RenderCalls()
    store.setMathRenderer { math, _ in
        calls.add(math.tex)
        return nil
    }
    let math = TranscriptMath(tex: "\\frac{", isDisplay: true)
    #expect(store.drawnImage(math) == nil)
    await waitFor { calls.all.count == 1 }
    try? await Task.sleep(for: .milliseconds(50))
    #expect(store.drawnImage(math) == nil)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(calls.all.count == 1)
    // The cache keeps only images: a view that comes later asks the renderer again.
    #expect(cache.usage.count == 0)
}

@Test func theCacheRemovesTheLeastRecentlyUsedFormulasOverItsLimit() async {
    // Each formula is 10 by 10 pixels: 100 bytes as a mask, which costs 256.
    let cache = TranscriptMathCache(byteLimit: 256 * 3)
    let store = TranscriptImageStore(mathCache: cache)
    store.setMathRenderer { _, _ in solidFormula(width: 10, height: 10) }
    let formulas = (0..<5).map { TranscriptMath(tex: "x_\($0)", isDisplay: false) }
    for math in formulas {
        _ = store.drawnImage(math)
        await waitFor { store.drawnImage(math) != nil }
        // The first formula is used again each time, so it stays.
        #expect(store.drawnImage(formulas[0]) != nil)
    }
    #expect(cache.usage.count == 3)
    #expect(cache.usage.bytes <= 256 * 3)
    #expect(cache.image(for: .init(math: formulas[0], fontSize: 17)) != nil)
    #expect(cache.image(for: .init(math: formulas[1], fontSize: 17)) == nil)
    #expect(cache.image(for: .init(math: formulas[4], fontSize: 17)) != nil)
    cache.removeAll()
    #expect(cache.usage.count == 0)
}

@Test func aStreamedFormulaKeepsItsLastImageAndIsDrawnOneLatexAtATime() async {
    let store = TranscriptImageStore()
    let calls = RenderCalls()
    store.setMathRenderer { math, _ in
        calls.add(math.tex)
        try? await Task.sleep(for: .milliseconds(100))
        return solidFormula(width: 10 * math.tex.count, height: 10)
    }
    let slot = TranscriptImageStore.MathSlot(block: "md-0", index: 0)
    func ask(_ tex: String) -> TranscriptImageStore.Formula {
        store.formula(for: TranscriptMath(tex: tex, isDisplay: true), fontSize: 17, in: slot)
    }
    func width(_ formula: TranscriptImageStore.Formula) -> CGFloat? {
        guard case .drawn(let image) = formula else { return nil }
        return image.size.width
    }
    // The same formula as its LaTeX grows.
    #expect(width(ask("x")) == nil)
    #expect(width(ask("x^2 +")) == nil)
    #expect(width(ask("x^2 + y")) == nil)
    await waitFor { width(ask("x^2 + y")) == 70 }
    // The middle LaTeX was replaced by the newest while the first was drawn.
    #expect(calls.all == ["x", "x^2 + y"])
    // While newer LaTeX is drawn, the last image is given for it.
    #expect(width(ask("x^2 + y^2")) == 70)
    // Not for another formula in the same slot.
    #expect(width(ask("\\sum_i i")) == nil)
    await waitFor { calls.all.count == 4 }
    #expect(calls.all.suffix(2) == ["x^2 + y^2", "\\sum_i i"])
}

@Test func onlyAFormulaThatCanGrowIntoTheNewOneIsShownMeanwhile() {
    func earlier(_ a: String, _ b: String, display: Bool = true) -> Bool {
        TranscriptImageStore.mayBeEarlierVersion(TranscriptMath(tex: a, isDisplay: true), of: TranscriptMath(tex: b, isDisplay: display))
    }
    #expect(earlier("x", "x^2"))
    #expect(earlier("\\frac{a}{}", "\\frac{a}{b}"))
    #expect(earlier("a + b", "a + c"))
    #expect(!earlier("x^2", "y^2"))
    #expect(!earlier("a + b + c + d", "a + x"))
    #expect(!earlier("x", "x^2", display: false))
}

@Test func aFormulasSlotIsTheSameInAnyPartOfItsBlock() {
    let block = MarkdownStreamParser.document(from: "| \\(a\\) | \\(b\\) |\n|---|---|\n| \\(c\\) | d |").blocks[0]
    let starts = block.spans.filter { $0.math != nil }.map(\.range.lowerBound)
    #expect(starts.count == 3)
    let slots = starts.map { TranscriptStyle.mathSlot(in: block, at: $0) }
    #expect(slots.map(\.index) == [0, 1, 2])
    #expect(Set(slots.map(\.block)) == [block.id])
}

/// Keeps what the store gives to run on the main queue, until the test runs it.
private final class Deliveries: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [@Sendable () -> Void] = []
    private var calls = 0
    func add(_ work: @escaping @Sendable () -> Void) { lock.withLock { waiting.append(work) } }
    var count: Int { lock.withLock { waiting.count } }
    func runAll() {
        let work = lock.withLock {
            defer { waiting = [] }
            return waiting
        }
        work.forEach { $0() }
    }
    func called() { lock.withLock { calls += 1 } }
    var callCount: Int { lock.withLock { calls } }
}

@Test func formulasThatArriveTogetherCallOnChangeOnce() async {
    let deliveries = Deliveries()
    let store = TranscriptImageStore(deliver: { deliveries.add($0) })
    store.setOnChange { deliveries.called() }
    store.setMathRenderer { _, _ in solidFormula(width: 10, height: 10) }
    let revision = store.revision
    for index in 0..<5 { _ = store.drawnImage(TranscriptMath(tex: "x_\(index)", isDisplay: false)) }
    await waitFor { store.revision == revision + 5 }
    #expect(store.revision == revision + 5)
    #expect(deliveries.count == 1)
    deliveries.runAll()
    #expect(deliveries.callCount == 1)
    // A formula that arrives after the call gets a call of its own.
    _ = store.drawnImage(TranscriptMath(tex: "y", isDisplay: false))
    await waitFor { deliveries.count == 1 }
    deliveries.runAll()
    #expect(deliveries.callCount == 2)
}

/// Holds a renderer until the test lets it go on.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let resume: Bool = lock.withLock {
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if resume { continuation.resume() }
        }
    }

    func open() {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            isOpen = true
            defer { self.waiters = [] }
            return self.waiters
        }
        waiters.forEach { $0.resume() }
    }
}

/// Keeps the work that the store runs once a failed formula may have settled.
private final class Settles: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [@Sendable () -> Void] = []
    func add(_ work: @escaping @Sendable () -> Void) { lock.withLock { waiting.append(work) } }
    var count: Int { lock.withLock { waiting.count } }
    func runAll() {
        let work = lock.withLock {
            defer { waiting = [] }
            return waiting
        }
        work.forEach { $0() }
    }
}

private func width(_ formula: TranscriptImageStore.Formula) -> CGFloat? {
    guard case .drawn(let image) = formula else { return nil }
    return image.size.width
}

private func isAsWritten(_ formula: TranscriptImageStore.Formula) -> Bool {
    if case .asWritten = formula { return true }
    return false
}

@Test func aFormulaThatFailsWhileItStreamsInDoesNotShowItsLatex() async {
    let settles = Settles()
    let store = TranscriptImageStore(settle: { settles.add($0) })
    let calls = RenderCalls()
    // Like a real renderer: LaTeX with an open brace cannot be drawn.
    store.setMathRenderer { math, _ in
        calls.add(math.tex)
        let open = math.tex.filter { $0 == "{" }.count
        let closed = math.tex.filter { $0 == "}" }.count
        return open == closed ? solidFormula(width: 10 * math.tex.count, height: 10) : nil
    }
    let slot = TranscriptImageStore.MathSlot(block: "md-0", index: 0)
    func ask(_ tex: String) -> TranscriptImageStore.Formula {
        store.formula(for: TranscriptMath(tex: tex, isDisplay: true), fontSize: 17, in: slot)
    }
    let full = "x = \\frac{a}{b}"
    for count in 1...full.count {
        let tex = String(full.prefix(count))
        #expect(!isAsWritten(ask(tex)))
        await waitFor { calls.all.last == tex }
        #expect(calls.all.last == tex)
        try? await Task.sleep(for: .milliseconds(5))
        #expect(!isAsWritten(ask(tex)))
    }
    // The failures of LaTeX that changed since settle to nothing.
    settles.runAll()
    #expect(width(ask(full)) == CGFloat(10 * full.count))

    // LaTeX that fails and then stays the same shows as written: it is not a prefix of a drawn formula forever.
    let broken = full + " + \\frac{c}{"
    #expect(width(ask(broken)) == CGFloat(10 * full.count))
    await waitFor { settles.count == 1 }
    #expect(width(ask(broken)) == CGFloat(10 * full.count))
    settles.runAll()
    #expect(isAsWritten(ask(broken)))
}

@Test func removingAllFormulasDrawsThemAgainInTheStoresThatShowThem() async {
    let cache = TranscriptMathCache()
    let deliveries = Deliveries()
    let store = TranscriptImageStore(mathCache: cache, deliver: { deliveries.add($0) })
    store.setOnChange { deliveries.called() }
    let calls = RenderCalls()
    store.setMathRenderer { math, _ in
        calls.add(math.tex)
        return solidFormula(width: 10 * calls.all.count, height: 10)
    }
    let math = TranscriptMath(tex: "x", isDisplay: false)
    _ = store.drawnImage(math)
    await waitFor { store.drawnImage(math) != nil }
    #expect(store.drawnImage(math)?.size.width == 10)
    deliveries.runAll()
    let revision = store.revision
    cache.removeAll()
    #expect(store.revision > revision)
    #expect(deliveries.count == 1)
    deliveries.runAll()
    #expect(store.drawnImage(math) == nil)
    await waitFor { store.drawnImage(math) != nil }
    #expect(store.drawnImage(math)?.size.width == 20)
    #expect(calls.all == ["x", "x"])
}

@Test func aDrawThatStartedBeforeRemoveAllIsNotKept() async {
    let cache = TranscriptMathCache()
    let store = TranscriptImageStore(mathCache: cache)
    let gates = [Gate(), Gate()]
    let calls = RenderCalls()
    store.setMathRenderer { math, _ in
        let call = calls.all.count
        calls.add(math.tex)
        await gates[call].wait()
        return solidFormula(width: 10 * (call + 1), height: 10)
    }
    let math = TranscriptMath(tex: "x", isDisplay: false)
    #expect(store.drawnImage(math) == nil)
    await waitFor { calls.all.count == 1 }
    cache.removeAll()
    // The new request does not wait for the draw from before.
    #expect(store.drawnImage(math) == nil)
    await waitFor { calls.all.count == 2 }
    #expect(calls.all.count == 2)
    gates[0].open()
    try? await Task.sleep(for: .milliseconds(50))
    #expect(cache.usage.count == 0)
    #expect(store.drawnImage(math) == nil)
    gates[1].open()
    await waitFor { store.drawnImage(math) != nil }
    #expect(store.drawnImage(math)?.size.width == 20)
    #expect(cache.image(for: .init(math: math, fontSize: 17))?.size.width == 20)
}

@Test func aStoreGivenAnotherCacheDrawsIntoIt() async {
    let first = TranscriptMathCache()
    let second = TranscriptMathCache()
    let store = TranscriptImageStore(mathCache: first)
    store.setMathRenderer { _, _ in solidFormula(width: 10, height: 10) }
    let math = TranscriptMath(tex: "x", isDisplay: false)
    _ = store.drawnImage(math)
    await waitFor { store.drawnImage(math) != nil }
    var revision = store.revision
    store.setMathCache(second)
    #expect(store.revision > revision)
    #expect(store.drawnImage(math) == nil)
    await waitFor { store.drawnImage(math) != nil }
    #expect(second.drawCount == 1)
    // The cache it used before no longer lays it out again.
    revision = store.revision
    first.removeAll()
    #expect(store.revision == revision)
    #expect(store.drawnImage(math) != nil)
}

@Test func newerLatexThatIsAlreadyDrawnReplacesTheWaitingLatex() async {
    // Room for one formula only.
    let cache = TranscriptMathCache(byteLimit: 256)
    let gate = Gate()
    let calls = RenderCalls()
    let renderer: TranscriptMathRenderer = { math, _ in
        calls.add(math.tex)
        if math.tex == "x" { await gate.wait() }
        return solidFormula(width: 10 * math.tex.count, height: 10)
    }
    let store = TranscriptImageStore(mathCache: cache)
    let other = TranscriptImageStore(mathCache: cache)
    store.setMathRenderer(renderer)
    other.setMathRenderer(renderer)
    let slot = TranscriptImageStore.MathSlot(block: "md-0", index: 0)
    func ask(_ tex: String) -> TranscriptImageStore.Formula {
        store.formula(for: TranscriptMath(tex: tex, isDisplay: true), fontSize: 17, in: slot)
    }
    _ = ask("x")
    await waitFor { calls.all == ["x"] }
    _ = ask("x+")
    // Another view draws the newest LaTeX first.
    let newest = TranscriptMath(tex: "x+y", isDisplay: true)
    _ = other.drawnImage(newest)
    await waitFor { other.drawnImage(newest) != nil }
    #expect(width(ask("x+y")) == 30)
    gate.open()
    await waitFor { cache.image(for: .init(math: TranscriptMath(tex: "x", isDisplay: true), fontSize: 17)) != nil }
    try? await Task.sleep(for: .milliseconds(50))
    // "x+" was not drawn, and the late image of "x" did not replace the newer one.
    #expect(calls.all == ["x", "x+y"])
    #expect(width(ask("x+y")) == 30)
    #expect(calls.all == ["x", "x+y"])
}

@Test func picturesColorsAndFormulasThatArriveTogetherCallOnChangeOnce() async {
    let deliveries = Deliveries()
    let store = TranscriptImageStore(deliver: { deliveries.add($0) })
    let picture = solidFormula(width: 4, height: 4).image
    store.setLoader({ _ in picture }, onChange: { deliveries.called() })
    store.setHighlighter { code, _ in [TranscriptCodeHighlight(range: 0..<code.utf16.count, color: TranscriptColor(red: 1, green: 0, blue: 0))] }
    store.setMathRenderer { _, _ in solidFormula(width: 10, height: 10) }
    let revision = store.revision
    _ = store.picture(for: TranscriptImage(source: "a.png", alt: "a"))
    _ = store.highlights(for: "code", text: "let x = 1", language: "swift")
    _ = store.drawnImage(TranscriptMath(tex: "x", isDisplay: false))
    await waitFor { store.revision == revision + 3 }
    #expect(store.revision == revision + 3)
    #expect(deliveries.count == 1)
    deliveries.runAll()
    #expect(deliveries.callCount == 1)
}

@Test func viewsShareTheirFormulasByDefault() async {
    let calls = RenderCalls()
    let renderer: TranscriptMathRenderer = { math, _ in
        calls.add(math.tex)
        return solidFormula(width: 10, height: 10)
    }
    let engines = [LayoutEngine(), LayoutEngine()]
    for engine in engines { engine.images.setMathRenderer(renderer) }
    // Other tests can use the shared cache at the same time, so this formula is one of its own.
    let math = TranscriptMath(tex: "x_{\(UUID().uuidString)}", isDisplay: false)
    _ = engines[0].images.drawnImage(math)
    await waitFor { engines[0].images.drawnImage(math) != nil }
    #expect(engines[1].images.drawnImage(math) != nil)
    #expect(calls.all == [math.tex])
}

@Test func aStoreKeepsTheFormulasOfItsDocumentHoweverManyThereAre() async {
    // Room for a few of the formulas only.
    let cache = TranscriptMathCache(byteLimit: 256 * 8)
    let store = TranscriptImageStore(mathCache: cache)
    let calls = RenderCalls()
    store.setMathRenderer { math, _ in
        calls.add(math.tex)
        return solidFormula(width: 10, height: 10)
    }
    let formulas = (0..<1100).map { TranscriptMath(tex: "x_{\($0)}", isDisplay: false) }
    for math in formulas { _ = store.drawnImage(math) }
    await waitFor { calls.all.count == 1100 && formulas.allSatisfy { store.drawnImage($0) != nil } }
    #expect(formulas.allSatisfy { store.drawnImage($0) != nil })
    #expect(calls.all.count == 1100)
    // A document without those blocks: their slots go.
    store.keepFormulas(of: MarkdownStreamParser.document(from: "Text", idPrefix: "other"))
    #expect(store.mathSlotCount == 0)
}
