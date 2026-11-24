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
        #expect(store.formula(for: math, fontSize: 17) == nil)
    }
    await waitFor { stores.allSatisfy { $0.formula(for: math, fontSize: 17) != nil } }
    #expect(stores.allSatisfy { $0.formula(for: math, fontSize: 17) != nil })
    #expect(calls.all == ["x^2"])
    // A store that comes later finds it drawn.
    let later = TranscriptImageStore(mathCache: cache)
    later.setMathRenderer(renderer)
    #expect(later.formula(for: math, fontSize: 17) != nil)
    // Another font size is another formula.
    #expect(later.formula(for: math, fontSize: 20) == nil)
    await waitFor { calls.all.count == 2 }
    #expect(cache.drawCount == 2)
}

@Test func aFormulaThatFailsIsNotDrawnAgain() async {
    let store = TranscriptImageStore()
    let calls = RenderCalls()
    store.setMathRenderer { math, _ in
        calls.add(math.tex)
        return nil
    }
    let math = TranscriptMath(tex: "\\frac{", isDisplay: true)
    #expect(store.formula(for: math, fontSize: 17) == nil)
    await waitFor { calls.all.count == 1 }
    try? await Task.sleep(for: .milliseconds(50))
    #expect(store.formula(for: math, fontSize: 17) == nil)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(calls.all.count == 1)
}

@Test func theCacheRemovesTheLeastRecentlyUsedFormulasOverItsLimit() async {
    // Each formula is 10 by 10 pixels: 100 bytes as a mask, which costs 256.
    let cache = TranscriptMathCache(byteLimit: 256 * 3)
    let store = TranscriptImageStore(mathCache: cache)
    store.setMathRenderer { _, _ in solidFormula(width: 10, height: 10) }
    let formulas = (0..<5).map { TranscriptMath(tex: "x_\($0)", isDisplay: false) }
    for math in formulas {
        _ = store.formula(for: math, fontSize: 17)
        await waitFor { store.formula(for: math, fontSize: 17) != nil }
        // The first formula is used again each time, so it stays.
        #expect(store.formula(for: formulas[0], fontSize: 17) != nil)
    }
    #expect(cache.usage.count == 3)
    #expect(cache.usage.bytes <= 256 * 3)
    #expect(cache.result(for: .init(math: formulas[0], fontSize: 17)) != nil)
    #expect(cache.result(for: .init(math: formulas[1], fontSize: 17)) == nil)
    #expect(cache.result(for: .init(math: formulas[4], fontSize: 17)) != nil)
    cache.removeAll()
    #expect(cache.usage.count == 0)
}
