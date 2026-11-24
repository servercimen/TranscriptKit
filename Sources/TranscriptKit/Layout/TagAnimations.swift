import CoreGraphics
import Foundation

/// An animated tag in a layout, gathered from its lines: what its animation
/// is made from and where it plays.
struct AnimatedTag: Sendable {
    let key: TagKey
    let animation: TranscriptDecoration.Animation
    /// One per line the tag's text is on, in text order, with where that
    /// line's coordinates start in the document: x where its glyphs start,
    /// y at its baseline.
    let parts: [(fragment: AnimatedFragment, origin: CGPoint)]
    /// The rows of the document its lines and shapes take up.
    let band: ClosedRange<CGFloat>

    var fragments: [TranscriptFragment] { parts.map(\.fragment.fragment) }

    /// Whether `other` draws the same glyphs in the same places: if so, an
    /// animation started from one can go on over the other. Only where each
    /// glyph starts counts: text that streams in after the tag can change
    /// its last glyph's advance (a kerning pair such as "y."), which moves
    /// nothing that is drawn.
    func isPlaced(like other: AnimatedTag) -> Bool {
        parts.count == other.parts.count && zip(parts, other.parts).allSatisfy { a, b in
            let mine = a.fragment.fragment.glyphs
            let theirs = b.fragment.fragment.glyphs
            return a.origin == b.origin && mine.count == theirs.count
                && zip(mine, theirs).allSatisfy { $0.index == $1.index && $0.bounds.origin == $1.bounds.origin }
        }
    }
}

extension DocumentLayout {
    /// The animated tags in `block` that have closed.
    static func closedAnimatedTags(in block: TranscriptBlock) -> Set<TagKey> {
        var keys: Set<TagKey> = []
        for span in block.spans {
            guard let tag = span.customTag, tag.decoration.animation != nil, !tag.isOpen else { continue }
            keys.insert(TagKey(block: block.id, start: span.range.lowerBound, name: tag.name))
        }
        return keys
    }

    /// The animated tags that have closed since `previous`, which this
    /// layout's document extends: those to animate now.
    ///
    /// Settled blocks never change, so only the blocks from `previous`'s
    /// first open one on are looked at.
    func newlyClosedAnimatedTags(since previous: DocumentLayout) -> [TagKey] {
        var found: [TagKey] = []
        for index in min(previous.settled.count, entryCount)..<entryCount {
            let block = entry(at: index).layout.block
            let closed = Self.closedAnimatedTags(in: block)
            guard !closed.isEmpty else { continue }
            var before: Set<TagKey> = []
            if index < previous.entryCount {
                let earlier = previous.entry(at: index).layout.block
                if earlier.id == block.id { before = Self.closedAnimatedTags(in: earlier) }
            }
            found += closed.subtracting(before).sorted { $0.start < $1.start }
        }
        return found
    }

    /// The tags of `keys` that are in this layout and have closed, in text
    /// order, each with its place among them: for tags whose animations
    /// start together.
    func tagsStartingTogether(_ keys: some Collection<TagKey>) -> [(tag: AnimatedTag, group: TranscriptAnimationGroup)] {
        var found: [(tag: AnimatedTag, block: Int)] = []
        for key in keys {
            guard let index = entryIndex(ofBlock: key.block), let tag = animatedTag(key) else { continue }
            found.append((tag, index))
        }
        found.sort { ($0.block, $0.tag.key.start, $0.tag.key.name) < ($1.block, $1.tag.key.start, $1.tag.key.name) }
        return found.enumerated().map { ($1.tag, TranscriptAnimationGroup(index: $0, count: found.count)) }
    }

    /// Where the block with id `id` is, looked for from the end.
    private func entryIndex(ofBlock id: String) -> Int? {
        var index = entryCount - 1
        while index >= 0, entry(at: index).layout.block.id != id { index -= 1 }
        return index >= 0 ? index : nil
    }

    /// The tag `key` names, if it is in this layout and has closed.
    func animatedTag(_ key: TagKey) -> AnimatedTag? {
        // Animated tags are almost always in the last blocks.
        guard let index = entryIndex(ofBlock: key.block) else { return nil }
        let entry = entry(at: index)
        var parts: [(fragment: AnimatedFragment, origin: CGPoint)] = []
        var animation: TranscriptDecoration.Animation?
        var top = CGFloat.greatestFiniteMagnitude
        var bottom = -CGFloat.greatestFiniteMagnitude
        for line in entry.layout.lines {
            guard let decorations = line.decorations else { continue }
            for fragment in decorations.animated where fragment.key == key {
                parts.append((fragment, CGPoint(x: line.frame.minX, y: entry.y + line.baseline)))
                animation = fragment.animation
                top = min(top, entry.y + line.frame.minY - decorations.inkAbove)
                bottom = max(bottom, entry.y + line.frame.maxY + decorations.inkBelow)
            }
        }
        guard let animation, !parts.isEmpty else { return nil }
        return AnimatedTag(key: key, animation: animation, parts: parts, band: top...bottom)
    }
}

/// The animated tags of a view that have closed and wait for the view's
/// `TranscriptAnimationTiming` to let them play, and which of them may play.
struct WaitingTags: Sendable {
    private(set) var keys: Set<TagKey> = []
    /// Waiting tags the app has asked to play (`playTagAnimations()`).
    private(set) var requested: Set<TagKey> = []

    /// Where the view is and what it shows, for `takeReady`.
    struct Viewer {
        var isInWindow: Bool
        /// The view or one of its ancestors is hidden or fully transparent.
        var isHidden: Bool
        /// The part of the view on screen, in its coordinates.
        var visibleRect: CGRect
        /// No more text is coming.
        var isFinished: Bool
    }

    var isEmpty: Bool { keys.isEmpty }

    mutating func add(_ keys: some Sequence<TagKey>) {
        self.keys.formUnion(keys)
    }

    /// Lets every tag waiting now play once the rest of the timing allows.
    mutating func request() {
        requested.formUnion(keys)
    }

    /// Empties the list, and returns the tags that waited.
    mutating func removeAll() -> Set<TagKey> {
        defer {
            keys.removeAll()
            requested.removeAll()
        }
        return keys
    }

    /// Takes the waiting tags that `timing` lets play now out of the list.
    /// A view that is not in a window plays none: nothing would show them.
    ///
    /// - Parameter band: the rows of the document a tag takes up, or nil
    ///   if the view's layout does not hold it.
    mutating func takeReady(timing: TranscriptAnimationTiming, viewer: Viewer,
                            band: (TagKey) -> ClosedRange<CGFloat>?) -> [TagKey] {
        guard !keys.isEmpty, viewer.isInWindow else { return [] }
        if timing.contains(.afterStreamFinishes), !viewer.isFinished { return [] }
        if timing.contains(.whenVisible), viewer.isHidden { return [] }
        var ready: [TagKey] = []
        for key in keys {
            if timing.contains(.whenRequested), !requested.contains(key) { continue }
            if timing.contains(.whenVisible) {
                guard let band = band(key), Self.isOnScreen(band, in: viewer.visibleRect) else { continue }
            }
            ready.append(key)
        }
        for key in ready {
            keys.remove(key)
            requested.remove(key)
        }
        return ready
    }

    /// Whether the tags wait only for a hidden view to show: nothing tells
    /// the view when an ancestor shows again, so it looks again later.
    func waitForHiddenView(timing: TranscriptAnimationTiming, viewer: Viewer) -> Bool {
        !keys.isEmpty && timing.contains(.whenVisible) && viewer.isInWindow && viewer.isHidden
    }

    /// Whether waiting tags keep waiting while the view is out of its
    /// window: they wait to be seen, or for the app, and neither has
    /// happened yet.
    static func keepWaitingOutsideWindow(_ timing: TranscriptAnimationTiming) -> Bool {
        !timing.isDisjoint(with: [.whenVisible, .whenRequested])
    }

    /// Whether a tag's rows count as on screen: all of them, or for a tag
    /// taller than what is visible, some of them.
    static func isOnScreen(_ band: ClosedRange<CGFloat>, in visible: CGRect) -> Bool {
        guard !visible.isNull, visible.height > 0 else { return false }
        if band.upperBound - band.lowerBound > visible.height {
            return band.upperBound > visible.minY && band.lowerBound < visible.maxY
        }
        return band.lowerBound >= visible.minY && band.upperBound <= visible.maxY
    }

    /// Whether a view is hidden: it or one of its ancestors, from the view
    /// up, is hidden or has an alpha of 0 (below 0.01, as hit testing has it).
    static func isHidden(_ chain: some Sequence<(isHidden: Bool, alpha: CGFloat)>) -> Bool {
        chain.contains { $0.isHidden || $0.alpha < 0.01 }
    }
}
