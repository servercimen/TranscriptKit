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

    /// The tag `key` names, if it is in this layout and has closed.
    func animatedTag(_ key: TagKey) -> AnimatedTag? {
        // Animated tags are almost always in the last blocks.
        var index = entryCount - 1
        while index >= 0, entry(at: index).layout.block.id != key.block { index -= 1 }
        guard index >= 0 else { return nil }
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
