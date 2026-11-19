import CoreGraphics
import CoreText
import Foundation
import QuartzCore

/// Plays a tag's animation with Core Animation.
///
/// Each glyph of the tag, and each path the animation shows, is drawn once
/// into a small image (a sprite) the way the view's own drawing draws it,
/// on whole pixels of the document; the sprites go on layers that the
/// animation's curves move. Core Animation runs the curves outside the
/// app's process, so the main thread does nothing per frame. At rest every
/// sprite sits exactly where the view draws that glyph or path, so when the
/// animation ends and the view draws the tag again, nothing moves.
enum TagAnimationPlayer {
    struct Appearance {
        /// The text's color, as the view draws it.
        var text: CGColor
        /// Whether custom colors take their dark values.
        var dark: Bool
        var scale: CGFloat
    }

    /// A drawn glyph or path, at rest, in document coordinates.
    struct Sprite {
        enum Kind: Equatable {
            /// The animation's `glyphs` entry for it, if any.
            case glyph(motion: Int?)
            /// An index into the animation's `paths`.
            case path(Int)
        }

        let kind: Kind
        let image: CGImage
        /// On whole pixels.
        let frame: CGRect
        /// For a glyph, the point it scales and turns around.
        let anchor: CGPoint
        let isOverText: Bool
    }

    /// The sprites for `tag` as `animation` shows it: every glyph of the
    /// tag, moving or not, and the animation's paths. Behind-text paths
    /// first, then glyphs, then paths over the text.
    static func sprites(for tag: AnimatedTag, animation: TranscriptAnimation, appearance: Appearance) -> [Sprite] {
        var motions: [Int: [Int: Int]] = [:]
        for (index, glyph) in animation.glyphs.enumerated() { motions[glyph.fragment, default: [:]][glyph.glyph] = index }
        var behind: [Sprite] = []
        var glyphs: [Sprite] = []
        var over: [Sprite] = []
        for (index, path) in animation.paths.enumerated() where tag.parts.indices.contains(path.fragment) {
            guard let sprite = pathSprite(path.path, origin: tag.parts[path.fragment].origin, index: index, appearance: appearance) else { continue }
            if path.path.layer == .behindText { behind.append(sprite) } else { over.append(sprite) }
        }
        for (fragmentIndex, part) in tag.parts.enumerated() {
            let fragment = part.fragment
            for (glyphIndex, source) in fragment.sources.enumerated() {
                let box = fragment.fragment.glyphs[glyphIndex].bounds
                let motion = motions[fragmentIndex]?[glyphIndex]
                let anchor = motion.map { animation.glyphs[$0].anchor } ?? CGPoint(x: 0.5, y: 0.85)
                let point = CGPoint(x: part.origin.x + box.minX + anchor.x * box.width, y: part.origin.y + box.minY + anchor.y * box.height)
                guard let (image, frame) = glyphImage(source, origin: part.origin, appearance: appearance) else { continue }
                glyphs.append(Sprite(kind: .glyph(motion: motion), image: image, frame: frame, anchor: point, isOverText: false))
            }
        }
        return behind + glyphs + over
    }

    /// A layer that never animates on its own: changes to it, adding it and
    /// removing it take effect at once, in whatever transaction they are
    /// made, without an explicit transaction that would commit separately.
    final class StillLayer: CALayer {
        override func action(forKey event: String) -> (any CAAction)? {
            NSNull()
        }
    }

    /// A layer holding `sprites`, with `animation`'s curves on them, its
    /// time 0 at `beginTime` (in `CACurrentMediaTime()`'s clock). Add it to
    /// a layer whose coordinates are the document's.
    static func makeLayer(sprites: [Sprite], animation: TranscriptAnimation, scale: CGFloat, beginTime: CFTimeInterval) -> CALayer {
        let arrays = ArrayCache()
        let container = StillLayer()
        container.frame = .zero
        for sprite in sprites {
            let layer = StillLayer()
            layer.contents = sprite.image
            layer.contentsScale = scale
            layer.frame = sprite.frame
            switch sprite.kind {
            case .glyph(let motion):
                guard let motion else { break }
                let glyph = animation.glyphs[motion]
                let frame = sprite.frame
                layer.anchorPoint = CGPoint(x: (sprite.anchor.x - frame.minX) / frame.width, y: (sprite.anchor.y - frame.minY) / frame.height)
                layer.position = sprite.anchor
                let curves: [(String, TranscriptCurve?)] = [
                    ("transform.translation.x", glyph.offsetX), ("transform.translation.y", glyph.offsetY),
                    ("transform.scale.x", glyph.scaleX), ("transform.scale.y", glyph.scaleY), ("transform.rotation.z", glyph.rotation),
                ]
                for (keyPath, curve) in curves {
                    if let curve { add(curve, keyPath: keyPath, to: layer, beginTime: beginTime, arrays: arrays) }
                }
            case .path(let index):
                let path = animation.paths[index]
                if let reveal = path.reveal {
                    // The layer clips its picture to its own bounds, which
                    // grow from the path's left edge. A mask layer would do
                    // the same at the cost of an offscreen pass every frame.
                    layer.contentsGravity = .left
                    layer.masksToBounds = true
                    layer.anchorPoint = CGPoint(x: 0, y: 0.5)
                    layer.position = CGPoint(x: sprite.frame.minX, y: sprite.frame.midY)
                    let ink = path.path.inkBounds
                    let lead = max(ink.minX + sprite.anchor.x - sprite.frame.minX, 0)
                    let width = sprite.frame.width
                    let shown = reveal.map { value -> CGFloat in
                        if value <= 0 { return 0 }
                        if value >= 1 { return width }
                        return min(lead + value * ink.width, width)
                    }
                    add(shown, keyPath: "bounds.size.width", to: layer, beginTime: beginTime, arrays: arrays)
                }
                if let opacity = path.opacity {
                    layer.opacity = Float(opacity.values[opacity.values.count - 1])
                    add(opacity, keyPath: "opacity", to: layer, beginTime: beginTime, arrays: arrays)
                }
            }
            container.addSublayer(layer)
        }
        return container
    }

    /// The value and key time arrays made so far. Glyphs usually share a
    /// curve, each starting a little later, so most animations can share
    /// their arrays: building thousands of numbers is most of what starting
    /// an animation would otherwise cost.
    ///
    /// They are kept as Swift arrays of numbers and assigned as they are:
    /// a cast to or from `NSArray` on every assignment would convert each
    /// element again, which costs more than the animations themselves.
    private final class ArrayCache {
        var values: [[CGFloat]: [Any]] = [:]
        var keyTimes: [[Double]: [NSNumber]] = [:]

        func values(_ values: [CGFloat]) -> [Any] {
            if let array = self.values[values] { return array }
            let array: [Any] = values.map { NSNumber(value: Double($0)) }
            self.values[values] = array
            return array
        }

        /// Rounded, so that curves that differ only in when they start share them.
        func keyTimes(_ times: [Double]) -> [NSNumber] {
            let rounded = times.map { ($0 * 1e9).rounded() / 1e9 }
            if let array = keyTimes[rounded] { return array }
            let array = rounded.map { NSNumber(value: $0) }
            keyTimes[rounded] = array
            return array
        }
    }

    /// Plays `curve` on `layer`'s `keyPath`, holding its first value before
    /// it starts and its last one after it ends.
    private static func add(_ curve: TranscriptCurve, keyPath: String, to layer: CALayer, beginTime: CFTimeInterval,
                            arrays: ArrayCache) {
        let span = curve.endTime - curve.startTime
        guard span > 0, curve.values.count > 1 else { return }
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = arrays.values(curve.values)
        animation.keyTimes = arrays.keyTimes(curve.times.map { ($0 - curve.startTime) / span })
        animation.calculationMode = .linear
        animation.duration = span
        animation.beginTime = beginTime + curve.startTime
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: keyPath)
    }

    // MARK: Drawing sprites

    /// A context for `frame` (document points, on whole pixels) at `scale`,
    /// drawing in document coordinates with a top-left origin, as the view's
    /// tiles do.
    private static func context(for frame: CGRect, scale: CGFloat) -> CGContext? {
        let width = Int((frame.width * scale).rounded())
        let height = Int((frame.height * scale).rounded())
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -frame.minX, y: -frame.minY)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        return context
    }

    /// `rect` grown to whole pixels.
    private static func pixelAligned(_ rect: CGRect, scale: CGFloat) -> CGRect {
        let minX = (rect.minX * scale).rounded(.down) / scale
        let minY = (rect.minY * scale).rounded(.down) / scale
        let maxX = (rect.maxX * scale).rounded(.up) / scale
        let maxY = (rect.maxY * scale).rounded(.up) / scale
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func glyphImage(_ source: GlyphSource, origin: CGPoint, appearance: Appearance) -> (CGImage, CGRect)? {
        let run = source.run
        let attributes = CTRunGetAttributes(run) as NSDictionary
        guard let font = attributes[kCTFontAttributeName].map({ $0 as! CTFont }) else { return nil }
        var glyph = CGGlyph()
        var position = CGPoint.zero
        CTRunGetGlyphs(run, CFRange(location: source.index, length: 1), &glyph)
        CTRunGetPositions(run, CFRange(location: source.index, length: 1), &position)
        var box = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .default, &glyph, &box, 1)
        // Font bounds are y-up from the glyph's origin; a little room for
        // antialiasing and for glyphs that reach past their bounds.
        let x = origin.x + position.x
        let baseline = origin.y - position.y
        let ink = CGRect(x: x + box.minX, y: baseline - box.maxY, width: box.width, height: box.height).insetBy(dx: -2, dy: -2)
        let frame = pixelAligned(ink, scale: appearance.scale)
        guard let context = context(for: frame, scale: appearance.scale) else { return nil }
        DocumentLayout.setGlyphColor(of: attributes, in: context, text: appearance.text, dark: appearance.dark)
        context.textPosition = origin
        CTRunDraw(run, context, CFRange(location: source.index, length: 1))
        return context.makeImage().map { ($0, frame) }
    }

    private static func pathSprite(_ path: TranscriptPath, origin: CGPoint, index: Int, appearance: Appearance) -> Sprite? {
        let ink = path.inkBounds
        guard !ink.isNull, !ink.isEmpty || path.stroke != nil else { return nil }
        let frame = pixelAligned(ink.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -1, dy: -1), scale: appearance.scale)
        guard let context = context(for: frame, scale: appearance.scale) else { return nil }
        context.translateBy(x: origin.x, y: origin.y)
        path.draw(in: context, dark: appearance.dark)
        guard let image = context.makeImage() else { return nil }
        // `anchor` carries the fragment's origin x, which the reveal mask
        // needs to find the path's left edge.
        return Sprite(kind: .path(index), image: image, frame: frame, anchor: CGPoint(x: origin.x, y: origin.y),
                      isOverText: path.layer == .overText)
    }
}
