import Foundation

/// Counters for benchmarks and tests: how much work the view did. Not part
/// of the public API; import with `@_spi(Diagnostics) import TranscriptKit`.
@_spi(Diagnostics)
public enum TranscriptDiagnostics {
    public struct Counters: Sendable {
        /// Layouts the view put on screen.
        public var installs = 0
        /// Tile redraws on the main thread.
        public var tileDraws = 0
        /// Tails drawn on the layout queue (see `TailRenderer`).
        public var tailFrames = 0
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var counters = Counters()
    nonisolated(unsafe) private static var tailEnabled = true

    /// Whether views draw the end of a growing document off the main thread
    /// (see `TailRenderer`). Benchmarks turn it off to compare. Set it before
    /// creating views.
    public static var drawsTailOffMainThread: Bool {
        get { lock.withLock { tailEnabled } }
        set { lock.withLock { tailEnabled = newValue } }
    }

    public static var current: Counters { lock.withLock { counters } }

    public static func reset() {
        lock.withLock { counters = Counters() }
    }

    static func count(_ counter: WritableKeyPath<Counters, Int>) {
        lock.withLock { counters[keyPath: counter] += 1 }
    }
}
