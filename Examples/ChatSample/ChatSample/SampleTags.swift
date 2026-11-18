import TranscriptKit
import UIKit

/// The custom tags the sample's text may use, and how they look. Every
/// stream and document in the app is parsed with them; any other tag shows
/// as written.
///
/// - `<mark>`: a hand-drawn highlighter stroke under the text.
/// - `<mention id="ana">@Ana</mention>`: a tinted pill with an outline;
///   tapping it opens `sample://person/ana`, which the app handles.
/// - `<status value="done|late|next">`: a solid pill, its color from the attribute.
/// - `<kbd>`: replaces the built-in one with an outlined key cap.
/// - `<todo>`: a zigzag under the text, a shape the app draws itself.
/// - `<hl>`: a soft highlighter band under the text, also the app's own
///   shape, which reaches a little left of the text where a line starts with it.
enum SampleTags {
    static let all: [TranscriptTag] = [
        TranscriptTag("mark", TranscriptDecoration(
            shapes: [.underline(.marker, color: TranscriptColor(UIColor.systemYellow.withAlphaComponent(0.6)))]
        )),
        TranscriptTag("mention") { attributes in
            TranscriptDecoration(
                traits: .bold,
                foreground: TranscriptColor(UIColor.systemIndigo),
                link: attributes["id"].map { "sample://person/\($0)" },
                padding: 5,
                shapes: [.pill(fill: TranscriptColor(UIColor.systemIndigo.withAlphaComponent(0.1)),
                               border: TranscriptColor(UIColor.systemIndigo.withAlphaComponent(0.45)))]
            )
        },
        TranscriptTag("status") { attributes in
            let color: UIColor = switch attributes["value"] {
            case "done": .systemGreen
            case "late": .systemRed
            default: .systemOrange
            }
            return TranscriptDecoration(traits: .bold, foreground: TranscriptColor(UIColor.white), padding: 6,
                                        shapes: [.pill(fill: TranscriptColor(color))])
        },
        TranscriptTag("kbd", TranscriptDecoration(
            traits: .code,
            padding: 4,
            shapes: [.pill(fill: TranscriptColor(UIColor.secondarySystemBackground), border: TranscriptColor(UIColor.systemGray3),
                           cornerRadius: 5)]
        )),
        TranscriptTag("todo", TranscriptDecoration(shapes: [.custom(Zigzag(color: TranscriptColor(UIColor.systemRed)))])),
        TranscriptTag("hl", TranscriptDecoration(
            shapes: [.custom(SoftUnderline(color: TranscriptColor(UIColor.systemYellow.withAlphaComponent(0.31))))]
        )),
    ]
}

/// A soft highlighter band under the text, from a little above the baseline
/// to the descenders, with round ends on every line. It reaches a little
/// past the text on both sides, left of the text column too.
struct SoftUnderline: TranscriptShapeRecipe {
    var color: TranscriptColor
    var overshoot: CGFloat = 2.5

    func paths(for fragment: TranscriptFragment) -> [TranscriptPath] {
        let top = -fragment.xHeight * 0.23
        let bottom = fragment.xHeight * 0.45
        let left = fragment.textRect.minX - overshoot
        // Where the line wraps, on through the space it breaks at.
        let right = fragment.textRect.maxX + overshoot + (fragment.isEnd ? 0 : fragment.xHeight * 0.5)
        guard right > left else { return [] }
        let band = CGRect(x: left, y: top, width: right - left, height: bottom - top)
        let radius = band.height / 2
        let path = CGPath(roundedRect: band, cornerWidth: min(radius, band.width / 2), cornerHeight: radius, transform: nil)
        return [TranscriptPath(path, fill: color)]
    }
}

/// A zigzag under the text: a shape the app makes itself, from the part of
/// the tag's text on each line.
struct Zigzag: TranscriptShapeRecipe {
    var color: TranscriptColor

    func paths(for fragment: TranscriptFragment) -> [TranscriptPath] {
        let text = fragment.textRect
        let y = fragment.underlineOffset + 1
        let path = CGMutablePath()
        path.move(to: CGPoint(x: text.minX, y: y))
        // A point every 3 points from the fragment's start, so the part
        // already on screen stays put as streamed text makes it longer.
        var step = 1
        while text.minX + CGFloat(step - 1) * 3 < text.maxX {
            let x = min(text.minX + CGFloat(step) * 3, text.maxX)
            path.addLine(to: CGPoint(x: x, y: y + (step % 2 == 1 ? 2 : 0)))
            step += 1
        }
        return [TranscriptPath(path, stroke: color, lineWidth: 1.2, lineCap: .round, lineJoin: .round)]
    }
}
