import CoreGraphics
import Foundation

/// How far the blocks that scroll sideways are scrolled, by block id (see
/// `TranscriptStyle.codeWraps` and `displayMathScrolls`). A block that grows
/// keeps its id, and with it its offset. An offset is cut to what the block
/// can scroll where it is used, so it stays valid when the block changes.
struct SideScroll: Equatable, Sendable {
    private var offsets: [String: CGFloat] = [:]

    static let none = SideScroll()

    var isEmpty: Bool { offsets.isEmpty }

    /// The offset set for a block, as set: not cut to what the block can scroll.
    subscript(id: String) -> CGFloat {
        get { offsets[id] ?? 0 }
        set { offsets[id] = newValue > 0 ? newValue : nil }
    }

    /// How far `layout`'s lines move left.
    func offset(of layout: BlockLayout) -> CGFloat {
        guard !offsets.isEmpty, layout.maximumScrollOffset > 0, let offset = offsets[layout.block.id] else { return 0 }
        return min(max(offset, 0), layout.maximumScrollOffset)
    }

    /// The offsets to keep when `new` replaces `old` on screen: those of the
    /// blocks that `new` keeps (see `keeps(_:from:in:)`).
    func kept(from old: DocumentLayout, in new: DocumentLayout) -> SideScroll {
        guard !offsets.isEmpty else { return self }
        var kept = SideScroll()
        for (id, offset) in offsets where Self.keeps(id, from: old, in: new) { kept.offsets[id] = offset }
        return kept
    }

    /// Whether the block with `id` keeps its offset when `new` replaces
    /// `old`: `new` still has it, of the same kind. A new document, whose
    /// first block is another one, keeps none.
    static func keeps(_ id: String, from old: DocumentLayout, in new: DocumentLayout) -> Bool {
        guard old.entryCount > 0, new.entryCount > 0, old.entry(at: 0).layout.block.id == new.entry(at: 0).layout.block.id,
              let before = old.entryIndex(ofBlock: id), let after = new.entryIndex(ofBlock: id) else { return false }
        return old.entry(at: before).layout.block.kind == new.entry(at: after).layout.block.kind
    }
}

extension SideScroll {
    /// How much of its speed a block that moves on after a pan keeps after
    /// each millisecond: the rate of `UIScrollView.DecelerationRate.normal`.
    static let decelerationRate: CGFloat = 0.998

    /// How far a block that moves at `velocity` points a second goes in
    /// `elapsed` seconds as it slows down, and its velocity then.
    static func decelerate(velocity: CGFloat, for elapsed: CFTimeInterval) -> (distance: CGFloat, velocity: CGFloat) {
        let decay = pow(decelerationRate, CGFloat(max(elapsed, 0) * 1000))
        return (velocity * (decay - 1) / (1000 * log(decelerationRate)), velocity * decay)
    }
}

extension DocumentLayout {
    /// A pan that starts this near a selection handle does not scroll a block.
    static let handleReach: CGFloat = 22

    /// The index of the entry whose block a pan scrolls sideways, or nil.
    /// The pan must start in the box of a block that scrolls, go more
    /// sideways than up or down, and go a way the block can still move. A
    /// pan that starts on a selection handle, at one of the offsets in
    /// `handles`, moves the handle instead.
    func sidePanEntryIndex(at point: CGPoint, velocity: CGPoint, scroll: SideScroll, handles: [Int] = []) -> Int? {
        guard abs(velocity.x) > abs(velocity.y), let index = sideScrollingEntryIndex(at: point) else { return nil }
        let block = entry(at: index).layout
        let offset = scroll.offset(of: block)
        if velocity.x > 0 ? offset <= 0 : offset >= block.maximumScrollOffset { return nil }
        let reach = Self.handleReach
        if handles.contains(where: { caretRect(at: $0, scroll: scroll).insetBy(dx: -reach, dy: -reach).contains(point) }) { return nil }
        return index
    }
}
