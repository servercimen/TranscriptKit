import CoreGraphics

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
}
