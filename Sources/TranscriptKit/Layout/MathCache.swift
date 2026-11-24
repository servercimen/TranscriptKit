import CoreGraphics
import Foundation

/// Keeps the formulas that a math renderer drew, so that views that share
/// the cache draw each formula once. Any thread.
///
/// Each `TranscriptTextView` uses `shared` unless the app gives it another
/// cache. A cache keeps the formulas of one renderer: give views whose
/// renderers draw a formula differently a cache each. The cache keeps only
/// images: when the renderer returns nil, each view keeps that result for
/// the formulas it shows, until its renderer is set again.
public final class TranscriptMathCache: @unchecked Sendable {
    /// The cache that views use unless the app gives them another.
    public static let shared = TranscriptMathCache()

    /// A formula at a font size, to half a point.
    struct Key: Hashable, Sendable {
        let math: TranscriptMath
        let size: Int

        init(math: TranscriptMath, fontSize: CGFloat) {
            self.math = math
            self.size = Int((fontSize * 2).rounded())
        }

        var fontSize: CGFloat { CGFloat(size) / 2 }
    }

    /// What the renderer gave for a formula.
    enum Result: Sendable {
        case drawn(TranscriptMathImage)
        /// The renderer returned nil.
        case failed
    }

    /// A draw of `key` that started after the cache was emptied `generation` times.
    private struct Draw: Hashable {
        let key: Key
        let generation: Int
    }

    private struct WeakStore {
        weak var store: TranscriptImageStore?
    }

    private let lock = NSLock()
    private var images: LeastRecentlyUsed<Key, TranscriptMathImage>
    /// For each draw in progress: what to call with its result.
    private var waiting: [Draw: [@Sendable (Result) -> Void]] = [:]
    private var stores: [ObjectIdentifier: WeakStore] = [:]
    /// How many stores were alive when the dead ones were last removed.
    private var liveStores = 0
    private var generation = 0
    private var draws = 0

    /// - Parameter byteLimit: how much memory the drawn formulas can use.
    ///   When they use more, the formulas used least recently are removed.
    public init(byteLimit: Int = 16 * 1024 * 1024) {
        images = LeastRecentlyUsed(costLimit: byteLimit)
    }

    /// Removes all the formulas, and lays out again the views that use the
    /// cache, so that they draw their formulas again. Use this when the
    /// renderer changes how it draws. Formulas that are being drawn now are
    /// not kept, and are drawn again when a view asks for them.
    public func removeAll() {
        let stores: [TranscriptImageStore] = lock.withLock {
            generation += 1
            images.removeAll()
            return self.stores.values.compactMap(\.store)
        }
        for store in stores { store.mathCacheWasEmptied(self) }
    }

    /// Tells `store` when the cache is emptied.
    func add(_ store: TranscriptImageStore) {
        lock.withLock {
            stores[ObjectIdentifier(store)] = WeakStore(store: store)
            if stores.count > liveStores * 2 + 64 {
                stores = stores.filter { $0.value.store != nil }
                liveStores = stores.count
            }
        }
    }

    /// The image for `key`, if the renderer has drawn it.
    func image(for key: Key) -> TranscriptMathImage? {
        lock.withLock { images.value(for: key) }
    }

    /// Calls `done` with the result for `key`: right away if the renderer
    /// has drawn it, or else once the renderer has given its result. The
    /// renderer is not called again for a formula that it is drawing.
    func draw(_ key: Key, with renderer: @escaping TranscriptMathRenderer, then done: @escaping @Sendable (Result) -> Void) {
        enum Step { case known(TranscriptMathImage), wait, start(Draw) }
        let step: Step = lock.withLock {
            if let known = images.value(for: key) { return .known(known) }
            let draw = Draw(key: key, generation: generation)
            if waiting[draw] != nil {
                waiting[draw]!.append(done)
                return .wait
            }
            waiting[draw] = [done]
            draws += 1
            return .start(draw)
        }
        switch step {
        case .known(let image):
            done(.drawn(image))
        case .wait:
            break
        case .start(let draw):
            Task.detached {
                let drawn = await renderer(key.math, key.fontSize)?.withAlphaAsMask()
                self.finish(draw, drawn.map(Result.drawn) ?? .failed)
            }
        }
    }

    private func finish(_ draw: Draw, _ result: Result) {
        let waiters: [@Sendable (Result) -> Void] = lock.withLock {
            if draw.generation == generation, case .drawn(let image) = result {
                images.set(image, for: draw.key, cost: Self.cost(of: image))
            }
            return waiting.removeValue(forKey: draw) ?? []
        }
        for done in waiters { done(result) }
    }

    /// Bytes, and at least a little for each formula, so that the number of
    /// formulas kept has a limit.
    static func cost(of formula: TranscriptMathImage) -> Int {
        max(formula.image.bytesPerRow * formula.image.height, 256)
    }

    /// How many times the renderer was called. For tests.
    var drawCount: Int { lock.withLock { draws } }

    /// How much memory the formulas use, in bytes, and how many there are. For tests.
    var usage: (bytes: Int, count: Int) { lock.withLock { (images.totalCost, images.count) } }
}
