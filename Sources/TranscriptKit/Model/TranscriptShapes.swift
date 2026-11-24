import CoreGraphics
import Foundation

/// Makes the shapes a custom tag draws around its text: a pill, a
/// hand-drawn underline, anything a path can describe.
///
/// Shapes are made when the text is laid out, once per line the tag's text
/// is on, and kept with the layout; drawing only fills and strokes them. So
/// `paths(for:)` runs on the layout queue, never while drawing, and the same
/// layout always draws the same pixels, on and off the main thread.
///
/// ```swift
/// struct Zigzag: TranscriptShapeRecipe {
///     var color: TranscriptColor
///
///     func paths(for fragment: TranscriptFragment) -> [TranscriptPath] {
///         let text = fragment.textRect
///         let y = fragment.underlineOffset + 1
///         let path = CGMutablePath()
///         path.move(to: CGPoint(x: text.minX, y: y))
///         // A point every 3 points from the fragment's start, so the part
///         // already on screen stays put as streamed text makes it longer.
///         var step = 1
///         while text.minX + CGFloat(step - 1) * 3 < text.maxX {
///             let x = min(text.minX + CGFloat(step) * 3, text.maxX)
///             path.addLine(to: CGPoint(x: x, y: y + (step % 2 == 1 ? 2 : 0)))
///             step += 1
///         }
///         return [TranscriptPath(path, stroke: color, lineWidth: 1.2, lineCap: .round)]
///     }
/// }
///
/// TranscriptTag("todo", TranscriptDecoration(shapes: [.custom(Zigzag(color: TranscriptColor(UIColor.systemRed)))]))
/// ```
///
/// - A recipe is a value: two that are equal must make the same paths. Keep
///   it small; recipes are compared on every update.
/// - Make the same paths for the same fragment every time. For a hand-drawn
///   look, take randomness from `fragment.seed`, never from a random number
///   generator or Swift's `Hasher`, which changes between launches.
/// - While text streams, a fragment grows to the right. Measure along x from
///   the fragment's start rather than as a fraction of its width, so that
///   what is already on screen stays put and only its end changes.
/// - Paths may reach up to `TranscriptPath.maximumOverhang` above or below
///   the line, and up to `TranscriptPath.maximumSideOverhang` left or right
///   of the text column, even when that is outside the view; beyond that they
///   are cut off. `fragment.visibleRect` is that area.
/// - The text doesn't move to make room: a shape that reaches left of the
///   text starts in the margin around the view, so leave room there (most
///   layouts have padding around their text).
public protocol TranscriptShapeRecipe: Hashable, Sendable {
    /// The paths for one line's part of the tag's text, in that line's
    /// coordinates (see `TranscriptFragment`).
    func paths(for fragment: TranscriptFragment) -> [TranscriptPath]
}

/// One line's part of a custom tag's text, given to a `TranscriptShapeRecipe`.
///
/// Coordinates are the line's: x from where its glyphs start, y down from
/// its baseline, so the text's top is at `-ascent` and its bottom at `descent`.
public struct TranscriptFragment: Sendable, Equatable {
    /// The tag's text on this line, from the font's ascent to its descent.
    public let textRect: CGRect
    /// `textRect` widened by the padding at whichever of the tag's ends are
    /// on this line, including the padding of tags inside it that start or
    /// end with it. A pill is drawn around this.
    public let rect: CGRect
    /// Whether the tag starts on this line; when it doesn't, the tag
    /// continues from the line above.
    public let isStart: Bool
    /// Whether the tag ends on this line; when it doesn't, it continues on
    /// the next line. While text streams, a tag that is still open ends
    /// where the text does for now.
    public let isEnd: Bool
    /// Metrics of the tag's font (not of a fallback font used for an emoji).
    public let ascent: CGFloat
    public let descent: CGFloat
    public let xHeight: CGFloat
    public let capHeight: CGFloat
    /// Where an underline goes, down from the baseline, and how thick it is.
    public let underlineOffset: CGFloat
    public let underlineThickness: CGFloat
    /// The same for the same tag on the same line in every layout, and
    /// different from one fragment to the next: for a hand-drawn look.
    public let seed: UInt64
    /// Where paths can be seen, in the line's coordinates: the text column
    /// widened by `TranscriptPath.maximumSideOverhang` on each side, and the
    /// line by `TranscriptPath.maximumOverhang` above and below. Its left
    /// edge is left of 0 by the line's indent (a list item's, say) plus the
    /// side overhang. Anything outside it is cut off.
    public let visibleRect: CGRect
    /// The glyphs of the tag's text on this line, in order, for a tag with
    /// an animation; empty for other tags.
    public let glyphs: [TranscriptGlyph]
    /// Whether the tag's text is right to left. Then the tag starts at the
    /// right end of `rect` and ends at its left end.
    public let isRightToLeft: Bool

    /// Whether the tag starts or ends at the left end of `rect`, and at its right end.
    var closesLeft: Bool { isRightToLeft ? isEnd : isStart }
    var closesRight: Bool { isRightToLeft ? isStart : isEnd }

    /// Made by layout; public so apps can test their recipes.
    public init(textRect: CGRect, rect: CGRect, isStart: Bool, isEnd: Bool, ascent: CGFloat, descent: CGFloat, xHeight: CGFloat,
                capHeight: CGFloat, underlineOffset: CGFloat, underlineThickness: CGFloat, seed: UInt64,
                visibleRect: CGRect = .infinite, glyphs: [TranscriptGlyph] = [], isRightToLeft: Bool = false) {
        self.textRect = textRect
        self.rect = rect
        self.isStart = isStart
        self.isEnd = isEnd
        self.ascent = ascent
        self.descent = descent
        self.xHeight = xHeight
        self.capHeight = capHeight
        self.underlineOffset = underlineOffset
        self.underlineThickness = underlineThickness
        self.seed = seed
        self.visibleRect = visibleRect
        self.glyphs = glyphs
        self.isRightToLeft = isRightToLeft
    }
}

/// A path to fill or stroke for a custom tag, behind or over the text.
public struct TranscriptPath: @unchecked Sendable {
    public enum Layer: Sendable, Equatable {
        case behindText
        case overText
    }

    /// How far a path may reach above or below its line, in points. Anything
    /// further is cut off: list items are only 6 points apart.
    public static let maximumOverhang: CGFloat = 6

    /// How far a path may reach left or right of the text column, in points.
    /// The view draws that far outside its frame, so a shape can start left
    /// of the text without the text moving. Anything further is cut off.
    public static let maximumSideOverhang: CGFloat = 12

    /// Immutable (copied when made), which is what makes this Sendable.
    public let path: CGPath
    public var fill: TranscriptColor?
    public var stroke: TranscriptColor?
    public var lineWidth: CGFloat
    public var lineCap: CGLineCap
    public var lineJoin: CGLineJoin
    /// Dash lengths for the stroke; empty for a solid line.
    public var dash: [CGFloat]
    public var layer: Layer

    public init(_ path: CGPath, fill: TranscriptColor? = nil, stroke: TranscriptColor? = nil, lineWidth: CGFloat = 1,
                lineCap: CGLineCap = .butt, lineJoin: CGLineJoin = .round, dash: [CGFloat] = [], layer: Layer = .behindText) {
        self.path = path.copy() ?? path
        self.fill = fill
        self.stroke = stroke
        self.lineWidth = lineWidth
        self.lineCap = lineCap
        self.lineJoin = lineJoin
        self.dash = dash
        self.layer = layer
    }

    /// What it covers, stroke included.
    var inkBounds: CGRect {
        let bounds = path.boundingBoxOfPath
        return stroke == nil ? bounds : bounds.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
    }

    func draw(in context: CGContext, dark: Bool, highContrast: Bool) {
        if let fill {
            context.addPath(path)
            context.setFillColor(fill.cgColor(dark: dark, highContrast: highContrast))
            context.fillPath()
        }
        if let stroke {
            context.addPath(path)
            context.setStrokeColor(stroke.cgColor(dark: dark, highContrast: highContrast))
            context.setLineWidth(lineWidth)
            context.setLineCap(lineCap)
            context.setLineJoin(lineJoin)
            context.setLineDash(phase: 0, lengths: dash)
            context.strokePath()
        }
    }
}

extension TranscriptDecoration {
    /// A shape a custom tag draws: a built-in one (`.pill`, `.underline`) or
    /// the app's own (`.custom`).
    public struct Shape: Hashable, Sendable {
        let recipe: any TranscriptShapeRecipe

        public init(_ recipe: some TranscriptShapeRecipe) {
            self.recipe = recipe
        }

        /// The app's own shape.
        public static func custom(_ recipe: some TranscriptShapeRecipe) -> Shape {
            Shape(recipe)
        }

        /// A rounded box around the text, filled, outlined or both. Give the
        /// decoration some `padding`, or the outline touches the glyphs. A
        /// pill that wraps is open where it breaks, with corners only at its
        /// real ends.
        ///
        /// - Parameters:
        ///   - cornerRadius: nil for round ends (a capsule).
        ///   - verticalPadding: how far it reaches above the font's ascent
        ///     and below its descent.
        public static func pill(fill: TranscriptColor? = nil, border: TranscriptColor? = nil, borderWidth: CGFloat = 1,
                                cornerRadius: CGFloat? = nil, verticalPadding: CGFloat = 0) -> Shape {
            Shape(PillRecipe(fill: fill, border: border, borderWidth: borderWidth, cornerRadius: cornerRadius,
                             verticalPadding: verticalPadding))
        }

        /// A line under the text, or for `.marker`, a band across its lower
        /// half like a highlighter stroke, drawn behind it.
        ///
        /// - Parameters:
        ///   - thickness: the line's width, or the marker band's height; nil
        ///     for one that suits the font.
        ///   - offset: moves it down (or up, if negative) from where it would go.
        public static func underline(_ style: LineStyle = .solid, color: TranscriptColor, thickness: CGFloat? = nil,
                                     offset: CGFloat = 0) -> Shape {
            Shape(UnderlineRecipe(style: style, color: color, thickness: thickness, offset: offset))
        }

        public enum LineStyle: Hashable, Sendable {
            case solid
            case dashed
            case dotted
            case wavy
            /// A highlighter stroke with a slightly wobbly, hand-drawn edge.
            case marker
        }

        public static func == (a: Shape, b: Shape) -> Bool {
            AnyHashable(a.recipe) == AnyHashable(b.recipe)
        }

        public func hash(into hasher: inout Hasher) {
            AnyHashable(recipe).hash(into: &hasher)
        }

        func paths(for fragment: TranscriptFragment) -> [TranscriptPath] {
            recipe.paths(for: fragment)
        }
    }
}

// MARK: Built-in shapes

struct PillRecipe: TranscriptShapeRecipe {
    var fill: TranscriptColor?
    var border: TranscriptColor?
    var borderWidth: CGFloat
    var cornerRadius: CGFloat?
    var verticalPadding: CGFloat

    func paths(for fragment: TranscriptFragment) -> [TranscriptPath] {
        let outer = fragment.rect.insetBy(dx: 0, dy: -verticalPadding)
        guard outer.width > 0, outer.height > 0 else { return [] }
        var result: [TranscriptPath] = []
        let inset = border == nil ? 0 : borderWidth / 2
        // The outline's middle runs half its width inside the box, so the
        // whole pill stays in `outer`.
        let box = outer.insetBy(dx: 0, dy: inset)
        let left = fragment.closesLeft ? box.minX + inset : box.minX
        let right = fragment.closesRight ? box.maxX - inset : box.maxX
        let shape = CGRect(x: left, y: box.minY, width: max(right - left, 0), height: box.height)
        let radius = min(cornerRadius ?? shape.height / 2, shape.height / 2, shape.width / 2)
        if let fill {
            result.append(TranscriptPath(Self.outline(of: shape, radius: radius, closedLeft: fragment.closesLeft,
                                                      closedRight: fragment.closesRight, forFill: true), fill: fill))
        }
        if let border, borderWidth > 0 {
            result.append(TranscriptPath(Self.outline(of: shape, radius: radius, closedLeft: fragment.closesLeft,
                                                      closedRight: fragment.closesRight, forFill: false),
                                         stroke: border, lineWidth: borderWidth))
        }
        return result
    }

    /// A box with rounded corners on its closed sides. For a fill, open
    /// sides are straight; for an outline, they are left out, as where a
    /// pill breaks across lines.
    static func outline(of rect: CGRect, radius: CGFloat, closedLeft: Bool, closedRight: Bool, forFill: Bool) -> CGPath {
        let path = CGMutablePath()
        let leftRadius = closedLeft ? radius : 0
        let rightRadius = closedRight ? radius : 0
        let topLeft = CGPoint(x: rect.minX, y: rect.minY)
        let topRight = CGPoint(x: rect.maxX, y: rect.minY)
        let bottomRight = CGPoint(x: rect.maxX, y: rect.maxY)
        let bottomLeft = CGPoint(x: rect.minX, y: rect.maxY)
        if forFill || (closedLeft && closedRight) {
            path.move(to: CGPoint(x: rect.minX + leftRadius, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - rightRadius, y: rect.minY))
            if closedRight {
                path.addArc(tangent1End: topRight, tangent2End: bottomRight, radius: rightRadius)
                path.addArc(tangent1End: bottomRight, tangent2End: bottomLeft, radius: rightRadius)
            } else {
                path.addLine(to: bottomRight)
            }
            path.addLine(to: CGPoint(x: rect.minX + leftRadius, y: rect.maxY))
            if closedLeft {
                path.addArc(tangent1End: bottomLeft, tangent2End: topLeft, radius: leftRadius)
                path.addArc(tangent1End: topLeft, tangent2End: topRight, radius: leftRadius)
            } else {
                path.addLine(to: topLeft)
            }
            path.closeSubpath()
        } else if closedLeft {
            // One stroke from the bottom edge, round the left end, to the top edge.
            path.move(to: bottomRight)
            path.addLine(to: CGPoint(x: rect.minX + leftRadius, y: rect.maxY))
            path.addArc(tangent1End: bottomLeft, tangent2End: topLeft, radius: leftRadius)
            path.addArc(tangent1End: topLeft, tangent2End: topRight, radius: leftRadius)
            path.addLine(to: topRight)
        } else if closedRight {
            path.move(to: topLeft)
            path.addLine(to: CGPoint(x: rect.maxX - rightRadius, y: rect.minY))
            path.addArc(tangent1End: topRight, tangent2End: bottomRight, radius: rightRadius)
            path.addArc(tangent1End: bottomRight, tangent2End: bottomLeft, radius: rightRadius)
            path.addLine(to: bottomLeft)
        } else {
            // Open at both ends: the top and bottom edges only.
            path.move(to: topLeft)
            path.addLine(to: topRight)
            path.move(to: bottomLeft)
            path.addLine(to: bottomRight)
        }
        return path
    }
}

struct UnderlineRecipe: TranscriptShapeRecipe {
    var style: TranscriptDecoration.Shape.LineStyle
    var color: TranscriptColor
    var thickness: CGFloat?
    var offset: CGFloat

    func paths(for fragment: TranscriptFragment) -> [TranscriptPath] {
        let text = fragment.textRect
        guard text.width > 0 else { return [] }
        if style == .marker { return [marker(fragment)] }
        let width = thickness ?? max(fragment.underlineThickness, 1)
        let y = fragment.underlineOffset + offset + width / 2
        let path = CGMutablePath()
        switch style {
        case .wavy:
            // Measured from the fragment's start, so a growing line keeps its waves.
            let amplitude = max(width, 1)
            let wavelength = max(width * 4, 4)
            let step = wavelength / 8
            path.move(to: CGPoint(x: text.minX, y: y))
            var distance: CGFloat = 0
            while distance < text.width {
                distance = min(distance + step, text.width)
                path.addLine(to: CGPoint(x: text.minX + distance, y: y + amplitude * sin(2 * .pi * distance / wavelength)))
            }
            return [TranscriptPath(path, stroke: color, lineWidth: width, lineCap: .round)]
        default:
            path.move(to: CGPoint(x: text.minX, y: y))
            path.addLine(to: CGPoint(x: text.maxX, y: y))
            switch style {
            case .dashed:
                return [TranscriptPath(path, stroke: color, lineWidth: width, dash: [width * 3, width * 2])]
            case .dotted:
                return [TranscriptPath(path, stroke: color, lineWidth: width, lineCap: .round, dash: [0, width * 2])]
            default:
                return [TranscriptPath(path, stroke: color, lineWidth: width)]
            }
        }
    }

    /// A highlighter band over the lower part of the text. Its edges wobble
    /// a little, by distance from the fragment's start and its seed, and its
    /// ends are cut at a slant where the tag starts and ends.
    private func marker(_ fragment: TranscriptFragment) -> TranscriptPath {
        let text = fragment.textRect
        let height = thickness ?? max(fragment.xHeight * 0.5 + fragment.descent * 0.55, 4)
        let bottom = fragment.descent * 0.55 + offset
        let top = bottom - height
        // Overshoots the text a little at the tag's ends, as a quick stroke does.
        let start = text.minX - (fragment.closesLeft ? 2 : 0)
        let end = text.maxX + (fragment.closesRight ? 2 : 0)
        let length = max(end - start, 0)
        let slant: CGFloat = min(3, length / 3)
        let phase1 = CGFloat(fragment.seed & 0xFFFF) / 0xFFFF * 2 * .pi
        let phase2 = CGFloat((fragment.seed >> 16) & 0xFFFF) / 0xFFFF * 2 * .pi
        let phase3 = CGFloat((fragment.seed >> 32) & 0xFFFF) / 0xFFFF * 2 * .pi
        func drift(_ distance: CGFloat) -> CGFloat { 0.8 * sin(distance / 47 + phase3) }
        func topEdge(_ distance: CGFloat) -> CGFloat { top + drift(distance) + 0.5 * sin(distance / 7 + phase1) }
        func bottomEdge(_ distance: CGFloat) -> CGFloat { bottom + drift(distance) + 0.5 * sin(distance / 9 + phase2) }

        // Points every 3 points from the start, and the end: the points
        // before the end stay the same as the band grows.
        var distances: [CGFloat] = []
        var distance: CGFloat = 0
        while distance < length {
            distances.append(distance)
            distance += 3
        }
        distances.append(length)
        let path = CGMutablePath()
        let startSlant = fragment.closesLeft ? slant : 0
        let endSlant = fragment.closesRight ? slant : 0
        path.move(to: CGPoint(x: start + startSlant, y: topEdge(0)))
        for d in distances.dropFirst() {
            path.addLine(to: CGPoint(x: start + min(d, length), y: topEdge(d)))
        }
        path.addLine(to: CGPoint(x: start + length - endSlant, y: bottomEdge(length)))
        for d in distances.reversed().dropFirst() {
            path.addLine(to: CGPoint(x: start + d, y: bottomEdge(d)))
        }
        path.closeSubpath()
        return TranscriptPath(path, fill: color)
    }
}

/// FNV-1a: a hash that is the same in every launch, unlike `Hasher`.
func stableHash(_ name: String, _ numbers: Int...) -> UInt64 {
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    func mix(_ byte: UInt8) {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01B3
    }
    for byte in name.utf8 { mix(byte) }
    for number in numbers {
        var value = UInt64(bitPattern: Int64(number))
        for _ in 0..<8 {
            mix(UInt8(value & 0xFF))
            value >>= 8
        }
    }
    return hash
}
