import CoreGraphics
import Foundation

/// Animates a custom tag's text and shapes when the tag finishes arriving:
/// letters that jump, a highlight that sweeps in, anything that moves the
/// tag's glyphs or reveals paths over time.
///
/// While a response streams, a tag with an animation shows its text as it
/// arrives but not its shapes. When its closing tag arrives, the view asks
/// the recipe for an animation and plays it with Core Animation, above the
/// rest of the text; meanwhile the tag's glyphs and shapes are left out of
/// the view's own drawing. When the animation ends, the view draws the tag
/// as usual again, shapes included, so the last frame should look exactly
/// like that: every glyph back in place and every path fully shown.
///
/// ```swift
/// struct Hop: TranscriptAnimationRecipe {
///     func animation(for fragments: [TranscriptFragment]) -> TranscriptAnimation {
///         var animation = TranscriptAnimation()
///         for (line, fragment) in fragments.enumerated() {
///             for (index, glyph) in fragment.glyphs.enumerated() {
///                 // One letter after the other, a few points up and back.
///                 let start = Double(glyph.index) * 0.03
///                 animation.glyphs.append(.init(fragment: line, glyph: index,
///                                               offsetY: .spring(peak: -4, start: start)))
///             }
///         }
///         return animation
///     }
/// }
///
/// TranscriptTag("hop", TranscriptDecoration(animation: .custom(Hop())))
/// ```
///
/// - Only tags that close while the view shows the text being appended are
///   animated. Text that is already complete when it is shown, such as
///   earlier messages, is drawn as it ends up.
/// - With Reduce Motion on, or `TranscriptTextView.animatesTags` off,
///   nothing is animated.
/// - A recipe is a value: two that are equal must make the same animation.
/// - `animation(for:)` runs on the main thread when the animation starts.
///   Keep it quick: a few curves per glyph is fine.
/// - Several tags can start at the same moment, for example when the
///   stream finishes or when they come on screen. To stagger them,
///   implement `animation(for:in:)` too, and delay each tag by its
///   `TranscriptAnimationGroup.index`.
/// - Glyphs and paths are drawn above the view's text, not cut off at its
///   edges, so they may move further than shapes may reach
///   (`TranscriptPath.maximumOverhang`); keep them near the text, or they
///   cover what is around it.
public protocol TranscriptAnimationRecipe: Hashable, Sendable {
    /// The animation for one tag, from its fragments: one per line its text
    /// is on, in order, each with its glyphs (`TranscriptFragment.glyphs`).
    func animation(for fragments: [TranscriptFragment]) -> TranscriptAnimation

    /// The animation for one tag of `group`, the tags whose animations start
    /// at the same moment in the same view. By default, `animation(for:)`.
    func animation(for fragments: [TranscriptFragment], in group: TranscriptAnimationGroup) -> TranscriptAnimation
}

extension TranscriptAnimationRecipe {
    public func animation(for fragments: [TranscriptFragment], in group: TranscriptAnimationGroup) -> TranscriptAnimation {
        animation(for: fragments)
    }
}

/// The tags whose animations start at the same moment in one view, and the
/// place of one of them, for a `TranscriptAnimationRecipe` that staggers them.
///
/// ```swift
/// func animation(for fragments: [TranscriptFragment], in group: TranscriptAnimationGroup) -> TranscriptAnimation {
///     var staggered = animation(for: fragments)
///     let delay = Double(group.index) * 0.15
///     for index in staggered.glyphs.indices {
///         staggered.glyphs[index].offsetY = staggered.glyphs[index].offsetY?.delayed(by: delay)
///     }
///     return staggered
/// }
/// ```
public struct TranscriptAnimationGroup: Sendable, Hashable {
    /// The tag's place among them, in text order, from 0.
    public var index: Int
    /// How many tags start together, 1 or more.
    public var count: Int

    public init(index: Int, count: Int) {
        self.index = max(index, 0)
        self.count = max(count, self.index + 1)
    }

    /// A tag that starts alone.
    public static let single = TranscriptAnimationGroup(index: 0, count: 1)
}

/// What a `TranscriptAnimationRecipe` plays: how each glyph moves and which
/// paths are shown, over time. Time starts at 0 when the tag's closing tag
/// is shown; the animation ends when its last curve does.
public struct TranscriptAnimation: Sendable {
    /// A glyph's motion, around `anchor`. A curve left nil keeps that
    /// property at rest (no offset, a scale of 1, no rotation).
    public struct Glyph: Sendable {
        /// Indexes into the recipe's `fragments`, and into that fragment's `glyphs`.
        public var fragment: Int
        public var glyph: Int
        /// In points: right and down.
        public var offsetX: TranscriptCurve?
        public var offsetY: TranscriptCurve?
        public var scaleX: TranscriptCurve?
        public var scaleY: TranscriptCurve?
        /// In radians, clockwise.
        public var rotation: TranscriptCurve?
        /// The point the glyph scales and turns around, as a fraction of its
        /// `bounds`: (0.5, 1) is the middle of its bottom edge.
        public var anchor: CGPoint

        public init(fragment: Int, glyph: Int, offsetX: TranscriptCurve? = nil, offsetY: TranscriptCurve? = nil,
                    scaleX: TranscriptCurve? = nil, scaleY: TranscriptCurve? = nil, rotation: TranscriptCurve? = nil,
                    anchor: CGPoint = CGPoint(x: 0.5, y: 0.85)) {
            self.fragment = fragment
            self.glyph = glyph
            self.offsetX = offsetX
            self.offsetY = offsetY
            self.scaleX = scaleX
            self.scaleY = scaleY
            self.rotation = rotation
            self.anchor = anchor
        }
    }

    /// A path shown during the animation, behind or over the glyphs as its
    /// `layer` says, in its fragment's coordinates.
    public struct Path: Sendable {
        public var fragment: Int
        public var path: TranscriptPath
        /// How much of it shows, from its left edge: 0 is none, 1 all of it.
        /// Nil shows all of it throughout.
        public var reveal: TranscriptCurve?
        /// From 0 (invisible) to 1. Nil is 1 throughout.
        public var opacity: TranscriptCurve?

        public init(fragment: Int, path: TranscriptPath, reveal: TranscriptCurve? = nil, opacity: TranscriptCurve? = nil) {
            self.fragment = fragment
            self.path = path
            self.reveal = reveal
            self.opacity = opacity
        }
    }

    public var glyphs: [Glyph]
    public var paths: [Path]

    public init(glyphs: [Glyph] = [], paths: [Path] = []) {
        self.glyphs = glyphs
        self.paths = paths
    }

    /// When the last curve ends, in seconds.
    public var duration: TimeInterval {
        var end: TimeInterval = 0
        for glyph in glyphs {
            for curve in [glyph.offsetX, glyph.offsetY, glyph.scaleX, glyph.scaleY, glyph.rotation] {
                if let curve { end = max(end, curve.endTime) }
            }
        }
        for path in paths {
            for curve in [path.reveal, path.opacity] {
                if let curve { end = max(end, curve.endTime) }
            }
        }
        return end
    }
}

/// A value over time, as points joined by straight lines: the value is the
/// first one before the first time and the last one after the last time.
///
/// Curves are sampled finely (60 points a second for `ramp` and `spring`),
/// so straight segments look smooth.
public struct TranscriptCurve: Sendable, Equatable {
    /// Seconds from the animation's start, not decreasing.
    public let times: [TimeInterval]
    public let values: [CGFloat]

    public init(times: [TimeInterval], values: [CGFloat]) {
        precondition(!times.isEmpty && times.count == values.count, "TranscriptCurve: one value per time, at least one")
        precondition(zip(times, times.dropFirst()).allSatisfy { $0 <= $1 }, "TranscriptCurve: times must not decrease")
        self.times = times
        self.values = values
    }

    /// The same value throughout.
    public init(constant value: CGFloat) {
        self.init(times: [0], values: [value])
    }

    public var startTime: TimeInterval { times[0] }
    public var endTime: TimeInterval { times[times.count - 1] }

    public func value(at time: TimeInterval) -> CGFloat {
        if time <= times[0] { return values[0] }
        if time >= endTime { return values[values.count - 1] }
        var low = 0
        var high = times.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if times[mid] <= time { low = mid } else { high = mid }
        }
        let span = times[high] - times[low]
        guard span > 0 else { return values[high] }
        let fraction = CGFloat((time - times[low]) / span)
        return values[low] + (values[high] - values[low]) * fraction
    }

    /// The same curve with every value changed by `transform`: a glyph's
    /// squash from its jump, say.
    public func map(_ transform: (CGFloat) -> CGFloat) -> TranscriptCurve {
        TranscriptCurve(times: times, values: values.map(transform))
    }

    /// The same curve, later by `delay` seconds.
    public func delayed(by delay: TimeInterval) -> TranscriptCurve {
        TranscriptCurve(times: times.map { $0 + delay }, values: values)
    }

    public enum Easing: Sendable, Equatable {
        case linear
        /// Starts slowly.
        case easeIn
        /// Ends slowly.
        case easeOut
        case easeInOut

        func callAsFunction(_ x: Double) -> Double {
            switch self {
            case .linear: x
            case .easeIn: x * x * x
            case .easeOut: 1 - pow(1 - x, 3)
            case .easeInOut: x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
            }
        }

        /// The x at which the curve reaches `y`, both from 0 to 1.
        func inverse(_ y: Double) -> Double {
            var low = 0.0
            var high = 1.0
            for _ in 0..<40 {
                let mid = (low + high) / 2
                if self(mid) < y { low = mid } else { high = mid }
            }
            return (low + high) / 2
        }
    }

    /// From `from` to `to`, between `start` and `start + duration` seconds.
    public static func ramp(from: CGFloat, to: CGFloat, start: TimeInterval = 0, duration: TimeInterval,
                            easing: Easing = .linear) -> TranscriptCurve {
        guard duration > 0 else { return TranscriptCurve(times: [start, start], values: [from, to]) }
        let steps = max(Int((duration * 60).rounded(.up)), 1)
        var times: [TimeInterval] = []
        var values: [CGFloat] = []
        for step in 0...steps {
            let x = Double(step) / Double(steps)
            times.append(start + duration * x)
            values.append(from + (to - from) * CGFloat(easing(x)))
        }
        return TranscriptCurve(times: times, values: values)
    }

    /// A push away from `rest` that springs back: at `start` the value
    /// leaves `rest`, reaches `rest + peak` first, swings past `rest` a
    /// little less each time, and comes to rest exactly at `rest`.
    ///
    /// - Parameters:
    ///   - frequency: swings per second.
    ///   - damping: from 0 (swings forever) to 1 (no swing back): how
    ///     quickly the swings die down. 0.3 gives two or three visible ones.
    public static func spring(peak: CGFloat, start: TimeInterval = 0, rest: CGFloat = 0, frequency: Double = 4,
                              damping: Double = 0.3) -> TranscriptCurve {
        let zeta = min(max(damping, 0.01), 0.99)
        let omega = 2 * .pi * max(frequency, 0.1) / sqrt(1 - zeta * zeta)
        let damped = omega * sqrt(1 - zeta * zeta)
        func raw(_ t: Double) -> Double { exp(-zeta * omega * t) * sin(damped * t) }
        // Scaled so that the first swing reaches exactly `peak`.
        let peakTime = atan(damped / (zeta * omega)) / damped
        let scale = Double(peak) / raw(peakTime)
        // Until the swings are under 0.3% of the first one.
        let length = -log(0.003 * abs(raw(peakTime))) / (zeta * omega)
        let steps = max(Int((length * 60).rounded(.up)), 2)
        var times: [TimeInterval] = []
        var values: [CGFloat] = []
        for step in 0...steps {
            let t = length * Double(step) / Double(steps)
            times.append(start + t)
            values.append(step == steps ? rest : rest + CGFloat(scale * raw(t)))
        }
        return TranscriptCurve(times: times, values: values)
    }
}

/// When a custom tag's animation plays, once its closing tag has arrived:
/// right away (`immediately`, the default), or not before every condition
/// in the set holds. Until then the tag shows its text without its shapes,
/// as it did while it was open.
///
/// ```swift
/// // On screen, and not before the whole answer is in:
/// view.tagAnimationTiming = [.whenVisible, .afterStreamFinishes]
/// ```
///
/// A tag that is still waiting when animations can no longer play (Reduce
/// Motion turned on, `animatesTags` turned off, the view leaving its window,
/// or a new document) is shown as it ends up, shapes and all.
public struct TranscriptAnimationTiming: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// As soon as the tag's closing tag arrives.
    public static let immediately: TranscriptAnimationTiming = []
    /// Not before the tag's text is on screen: a tag that closes while it is
    /// scrolled out of view plays when it is scrolled into view.
    public static let whenVisible = TranscriptAnimationTiming(rawValue: 1 << 0)
    /// Not before the stream has finished (`TranscriptStream.finish()`), or
    /// the view shows a document that was set directly rather than streamed.
    public static let afterStreamFinishes = TranscriptAnimationTiming(rawValue: 1 << 1)
    /// Not before the app asks: `TranscriptTextView.playTagAnimations()`
    /// lets every tag waiting at that moment play.
    public static let whenRequested = TranscriptAnimationTiming(rawValue: 1 << 2)
}

/// One glyph of a custom tag's text, for a `TranscriptAnimationRecipe`. In
/// its fragment's coordinates (x from where the line's glyphs start, y down
/// from its baseline).
public struct TranscriptGlyph: Sendable, Equatable {
    /// Its typographic box: from where it starts, as wide as its advance,
    /// from its font's ascent to its descent.
    public let bounds: CGRect
    /// Where its text starts, in UTF-16 units from the start of the tag's text.
    public let index: Int

    public init(bounds: CGRect, index: Int) {
        self.bounds = bounds
        self.index = index
    }
}

extension TranscriptDecoration {
    /// An animation a custom tag plays when it finishes arriving.
    public struct Animation: Hashable, Sendable {
        let recipe: any TranscriptAnimationRecipe

        public init(_ recipe: some TranscriptAnimationRecipe) {
            self.recipe = recipe
        }

        /// The app's own animation.
        public static func custom(_ recipe: some TranscriptAnimationRecipe) -> Animation {
            Animation(recipe)
        }

        public static func == (a: Animation, b: Animation) -> Bool {
            AnyHashable(a.recipe) == AnyHashable(b.recipe)
        }

        public func hash(into hasher: inout Hasher) {
            AnyHashable(recipe).hash(into: &hasher)
        }

        func animation(for fragments: [TranscriptFragment], in group: TranscriptAnimationGroup = .single) -> TranscriptAnimation {
            recipe.animation(for: fragments, in: group)
        }
    }
}
