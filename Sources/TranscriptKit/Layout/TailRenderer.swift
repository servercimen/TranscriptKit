import CoreGraphics
import Foundation
import IOSurface

/// Draws the end of a growing document on the layout queue, so that the
/// main thread does not have to.
///
/// While a response streams, almost every update only adds to the last few
/// lines. Redrawing those lines inside the view's tiles costs the main thread
/// a backing-store update and a Core Graphics replay every frame. Instead,
/// the bottom `height` points of the document (the *tail*) are drawn here,
/// into one of a few IOSurfaces, and the view shows the surface as a layer's
/// contents: on the main thread that is a pointer swap, committed in the same
/// transaction as the layout it belongs to.
///
/// The tail starts at `top`, which stays put while the text fills the
/// strip and moves down to the start of the last line when the text gets
/// within `margin` of its bottom. The view's tiles draw only above `top`, so
/// every line is drawn by exactly one of the two.
///
/// Not thread-safe: use it from one queue (the layout engine's).
final class TailRenderer {
    static let height: CGFloat = 256
    /// The strip reaches this far left and right of the text column, where
    /// tags' shapes may draw (see `TranscriptPath.maximumSideOverhang`).
    static let sideMargin = TranscriptPath.maximumSideOverhang
    /// The tail moves down once the text is closer than this to its bottom.
    static let margin: CGFloat = 48
    /// More surfaces than this means the render server is holding on to
    /// them; frames are then skipped rather than allocating further.
    private static let maximumSurfaces = 4

    struct Colors: @unchecked Sendable {
        var text: CGColor
        var codeBackground: CGColor
        var accent: CGColor
        /// Whether custom tags' colors take their dark values.
        var dark = false
    }

    /// One drawn tail: show `surface` at `top`, `TailRenderer.height` points tall.
    struct Frame: @unchecked Sendable {
        let surface: IOSurface
        let top: CGFloat
    }

    private var colors: Colors
    private var scale: CGFloat

    /// Where the tail starts, in document points, while it is in use.
    private(set) var top: CGFloat?
    private var width: CGFloat = 0
    /// The tail as drawn so far, in a CPU bitmap; each frame copies the rows
    /// that changed into a surface.
    private var context: CGContext?
    private var pixelWidth = 0
    private var pixelHeight = 0
    /// Bottom of what the last frame drew, so the next one clears no further.
    private var drawnBottom: CGFloat = 0

    private final class Slot {
        let surface: IOSurface
        /// The frame whose rows this surface holds.
        var frame = Int.min
        init(surface: IOSurface) { self.surface = surface }
    }
    private var slots: [Slot] = []
    private var frame = 0
    /// Rows drawn in each recent frame, so a surface that missed frames gets
    /// exactly what changed since it was last filled.
    private var changedRows: [Int: Range<Int>] = [:]
    private static let rowHistory = 8
    /// Surfaces filled before this frame need every row.
    private var fullCopyFrom = 0
    /// The surfaces most recently handed out, which the view may be showing
    /// or about to show; they are not refilled.
    private var handedOut: [ObjectIdentifier] = []

    init(colors: Colors, scale: CGFloat) {
        self.colors = colors
        self.scale = scale
    }

    /// New colours (light or dark) or a new display scale. The tail is
    /// forgotten, so the next frame draws it all again.
    func configure(colors: Colors, scale: CGFloat) {
        self.colors = colors
        self.scale = scale
        reset()
    }

    /// Stops using the tail and frees its memory. The next `render` starts
    /// a new one.
    func reset() {
        top = nil
        context = nil
        slots.removeAll()
        changedRows.removeAll()
        handedOut.removeAll()
    }

    /// Draws `layout`'s tail and returns the surface to show.
    ///
    /// - Parameter changedTop: nothing above this y differs from the layout
    ///   drawn last time, or nil if anything may have.
    /// - Returns: nil if no surface is free; the caller then draws the tail
    ///   some other way.
    /// - Parameter restyled: blocks above `changedTop` drawn differently in
    ///   place; the parts of them inside the tail are drawn again.
    /// - Parameter hiding: animated tags playing their animation, which the
    ///   view draws itself; see `DocumentLayout.draw`.
    /// - Parameter fadingTop: the top of the text that fades in. A strip that
    ///   moves down starts no lower, while it can hold the text, so the tail
    ///   and not the tiles draws that text when it stops fading.
    func render(_ layout: DocumentLayout, changedTop: CGFloat?, restyled: [CGRect] = [], hiding: TagHiding = .none,
                fadingTop: CGFloat? = nil) -> Frame? {
        if layout.width != width || context == nil {
            guard makeContext(width: layout.width) else { return nil }
            top = nil
        }
        guard let context else { return nil }

        // Keep the strip where it is while the change is inside it and the
        // text still fits; otherwise start it at the last line.
        var start: CGFloat
        let currentTop: CGFloat
        if let top, let changedTop, changedTop >= top, layout.height <= top + Self.height - Self.margin {
            currentTop = top
            start = changedTop
            for rect in restyled where rect.maxY > top { start = min(start, max(rect.minY, top)) }
        } else {
            var newTop = Self.lastLineTop(of: layout, scale: scale)
            if let fadingTop {
                let fits = ((layout.height - Self.height + Self.margin) * scale).rounded(.up) / scale
                newTop = min(newTop, max((max(fadingTop, 0) * scale).rounded(.down) / scale, fits))
            }
            currentTop = newTop
            start = currentTop
            drawnBottom = currentTop + Self.height
            fullCopyFrom = frame + 1
        }
        top = currentTop

        // Clear down to whatever the previous frame drew, in case the text
        // got shorter, and draw down to the text's bottom.
        // On whole pixels, so a band redrawn on its own gives exactly the
        // pixels drawing everything at once would.
        // Tags' shapes may reach a little below the text.
        let overhang = TranscriptPath.maximumOverhang
        let bottom = min((((max(layout.height + overhang, drawnBottom) + 2) * scale).rounded(.up)) / scale, currentTop + Self.height)
        drawnBottom = min(layout.height + overhang, currentTop + Self.height)
        start = min(max(((start * scale).rounded(.down)) / scale, currentTop), bottom)
        if bottom > start {
            let band = CGRect(x: -Self.sideMargin, y: start, width: layout.width + 2 * Self.sideMargin, height: bottom - start)
            context.saveGState()
            // Top-left origin, in document points.
            context.translateBy(x: 0, y: CGFloat(pixelHeight))
            context.scaleBy(x: scale, y: -scale)
            context.translateBy(x: Self.sideMargin, y: -currentTop)
            context.clip(to: band)
            context.clear(band)
            layout.draw(in: context, dirtyRect: band, text: colors.text, codeBackground: colors.codeBackground, accent: colors.accent,
                        dark: colors.dark, hiding: hiding)
            context.restoreGState()
        }
        let firstRow = max(0, min(pixelHeight, Int(((start - currentTop) * scale).rounded(.down))))
        let endRow = max(firstRow, min(pixelHeight, Int(((bottom - currentTop) * scale).rounded(.up))))

        frame += 1
        changedRows[frame] = firstRow..<endRow
        changedRows[frame - Self.rowHistory] = nil
        guard let slot = freeSlot() else { return nil }
        copy(into: slot)
        handedOut.append(ObjectIdentifier(slot.surface))
        if handedOut.count > 2 { handedOut.removeFirst(handedOut.count - 2) }
        return Frame(surface: slot.surface, top: currentTop)
    }

    /// A surface that is neither on screen nor about to be.
    private func freeSlot() -> Slot? {
        if let slot = slots.first(where: { !$0.surface.isInUse && !handedOut.contains(ObjectIdentifier($0.surface)) }) {
            return slot
        }
        guard slots.count < Self.maximumSurfaces, let surface = makeSurface() else { return nil }
        let slot = Slot(surface: surface)
        slots.append(slot)
        return slot
    }

    /// Brings `slot` up to the current frame by copying the rows that changed
    /// since it was last filled.
    private func copy(into slot: Slot) {
        guard let context, let source = context.data else { return }
        var rows: Range<Int>
        if slot.frame < fullCopyFrom || slot.frame <= frame - Self.rowHistory {
            rows = 0..<pixelHeight
        } else {
            rows = changedRows[frame] ?? 0..<0
            for earlier in (slot.frame + 1)..<frame {
                guard let other = changedRows[earlier], !other.isEmpty else { continue }
                rows = rows.isEmpty ? other : min(rows.lowerBound, other.lowerBound)..<max(rows.upperBound, other.upperBound)
            }
        }
        let surface = slot.surface
        surface.lock(options: [], seed: nil)
        let destination = surface.baseAddress
        let sourceBytesPerRow = context.bytesPerRow
        let destinationBytesPerRow = surface.bytesPerRow
        let rowBytes = min(sourceBytesPerRow, destinationBytesPerRow)
        for row in rows {
            memcpy(destination + row * destinationBytesPerRow, source + row * sourceBytesPerRow, rowBytes)
        }
        surface.unlock(options: [], seed: nil)
        slot.frame = frame
    }

    private func makeContext(width: CGFloat) -> Bool {
        let pixelWidth = Int(((width + 2 * Self.sideMargin) * scale).rounded())
        let pixelHeight = Int((Self.height * scale).rounded())
        guard pixelWidth > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: pixelWidth * 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return false
        }
        self.context = context
        self.width = width
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        slots.removeAll()
        handedOut.removeAll()
        return true
    }

    private func makeSurface() -> IOSurface? {
        guard let surface = IOSurface(properties: [
            .width: pixelWidth, .height: pixelHeight, .bytesPerElement: 4,
            .pixelFormat: 0x42475241, // 'BGRA': premultiplied, as Core Graphics drew it
        ]) else { return nil }
        // Tagged like the bitmap it is copied from, so Core Animation matches
        // its colours to the tiles' instead of reading them as device RGB.
        if let space = CGColorSpace(name: CGColorSpace.sRGB), let properties = space.copyPropertyList() {
            IOSurfaceSetValue(surface, kIOSurfaceColorSpace, properties)
        }
        return surface
    }

    /// The top of the document's last line, on a pixel boundary.
    static func lastLineTop(of layout: DocumentLayout, scale: CGFloat) -> CGFloat {
        guard layout.entryCount > 0 else { return 0 }
        let entry = layout.entry(at: layout.entryCount - 1)
        // What the line draws, which its tags' shapes may raise.
        var lineTop = entry.layout.lines.last.map { entry.y + $0.inkTop } ?? entry.y
        if let table = entry.layout.table, table.rowY.count >= 2 {
            // A table grows by its last row, grid and all.
            lineTop = entry.y + table.rowY[table.rowY.count - 2] - BlockLayout.Table.changeMargin
        }
        return (max(0, lineTop) * scale).rounded(.down) / scale
    }

    /// The pixels the tail currently holds, for tests.
    func currentPixels() -> [UInt8]? {
        guard let context, let data = context.data else { return nil }
        return Array(UnsafeRawBufferPointer(start: data, count: context.bytesPerRow * pixelHeight))
    }
}
