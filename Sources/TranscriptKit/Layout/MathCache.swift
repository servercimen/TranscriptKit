import CoreGraphics
import Foundation

/// Keeps the formulas that a math renderer drew, so that views that share
/// the cache draw each formula once. Any thread.
///
/// Each `TranscriptTextView` uses `shared` unless the app gives it another
/// cache. A cache keeps the formulas of one renderer: give views whose
/// renderers draw a formula differently a cache each.
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
        /// The renderer returned nil: the formula shows its LaTeX as written.
        case failed

        /// Bytes. A formula that failed costs a little too, so that the
        /// number of formulas kept has a limit.
        var cost: Int {
            guard case .drawn(let formula) = self else { return 256 }
            return max(formula.image.bytesPerRow * formula.image.height, 256)
        }
    }

    private let lock = NSLock()
    private var results: LeastRecentlyUsed<Key, Result>
    /// For each formula that is being drawn: what to call with its result.
    private var waiting: [Key: [@Sendable (Result) -> Void]] = [:]
    private var generation = 0
    private var draws = 0

    /// - Parameter byteLimit: how much memory the drawn formulas can use.
    ///   When they use more, the formulas used least recently are removed.
    public init(byteLimit: Int = 16 * 1024 * 1024) {
        results = LeastRecentlyUsed(costLimit: byteLimit)
    }

    /// Removes all the formulas. Views draw a formula again the next time
    /// they lay it out. Use this when the renderer changes how it draws.
    public func removeAll() {
        lock.withLock {
            generation += 1
            results.removeAll()
        }
    }

    /// The result for `key`, if the renderer has given it.
    func result(for key: Key) -> Result? {
        lock.withLock { results.value(for: key) }
    }

    /// Calls `done` with the result for `key`: right away if the renderer
    /// has given it, or else once it has drawn the formula. The renderer is
    /// not called again for a formula that it is drawing.
    func draw(_ key: Key, with renderer: @escaping TranscriptMathRenderer, then done: @escaping @Sendable (Result) -> Void) {
        enum Step { case known(Result), wait, start(Int) }
        let step: Step = lock.withLock {
            if let known = results.value(for: key) { return .known(known) }
            if waiting[key] != nil {
                waiting[key]!.append(done)
                return .wait
            }
            waiting[key] = [done]
            draws += 1
            return .start(generation)
        }
        switch step {
        case .known(let result):
            done(result)
        case .wait:
            break
        case .start(let generation):
            Task.detached {
                let drawn = await renderer(key.math, key.fontSize)?.withAlphaAsMask()
                self.finish(key, drawn.map(Result.drawn) ?? .failed, generation: generation)
            }
        }
    }

    private func finish(_ key: Key, _ result: Result, generation: Int) {
        let waiters: [@Sendable (Result) -> Void] = lock.withLock {
            if generation == self.generation { results.set(result, for: key, cost: result.cost) }
            return waiting.removeValue(forKey: key) ?? []
        }
        for done in waiters { done(result) }
    }

    /// How many times the renderer was called. For tests.
    var drawCount: Int { lock.withLock { draws } }

    /// How much memory the formulas use, in bytes, and how many there are. For tests.
    var usage: (bytes: Int, count: Int) { lock.withLock { (results.totalCost, results.count) } }
}
