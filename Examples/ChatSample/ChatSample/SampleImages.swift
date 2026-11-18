import TranscriptKit
import UIKit

/// Pictures for the sample, drawn on the fly so it needs no network and no
/// assets: "photos" by name, and pictures the user attached.
///
/// `loader` is what the text views use for Markdown images. It serves only
/// `sample://` addresses. Anything else, such as an `https://` image a model
/// wrote, gets nil, and the text shows the image's alt text: fetching a
/// model's image URL could send data from the conversation to that server.
enum SampleImages {
    /// For `TranscriptText.imageLoader`. Runs off the main thread.
    static let loader: @Sendable (TranscriptImage) async -> CGImage? = { image in
        guard let url = URL(string: image.source), url.scheme == "sample", let kind = url.host() else { return nil }
        let name = url.lastPathComponent
        switch kind {
        case "photo": return cache.picture(named: name)
        case "attachment": return cache.attachment(name)
        default: return nil
        }
    }

    /// A generated photo, for native views.
    static func photo(_ name: String) -> UIImage {
        UIImage(cgImage: cache.picture(named: name), scale: 3, orientation: .up)
    }

    /// An attachment for a picture the user picked, also served at
    /// `sample://attachment/<id>`.
    ///
    /// The picture is redrawn upright and at most 1,200 pixels on its longer
    /// side. The text view draws a `CGImage`, which has no orientation, so a
    /// portrait camera photo would otherwise come out sideways there, and at
    /// its full 12 megapixels.
    static func attach(_ image: UIImage, id: String = UUID().uuidString) -> Attachment {
        let upright = prepared(image)
        if let picture = upright.cgImage { cache.store(picture, attachment: id) }
        return Attachment(id: id, image: upright)
    }

    private static func prepared(_ image: UIImage) -> UIImage {
        // `size` is already in the image's orientation.
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let factor = min(1, 1200 / max(pixels.width, pixels.height, 1))
        let size = CGSize(width: (pixels.width * factor).rounded(), height: (pixels.height * factor).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// A stand-in for a photo from the library, for launching with `-attachSample`.
    static func samplePhoto() -> UIImage { photo("river") }

    private static let cache = Cache()

    /// Pictures are drawn once and shared by every text view: each view has
    /// its own image store and asks for them separately.
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var pictures: [String: CGImage] = [:]
        private var attachments: [String: CGImage] = [:]

        func picture(named name: String) -> CGImage {
            if let picture = lock.withLock({ pictures[name] }) { return picture }
            let picture = SampleImages.draw(name)
            lock.withLock { pictures[name] = picture }
            return picture
        }

        func attachment(_ id: String) -> CGImage? {
            lock.withLock { attachments[id] }
        }

        func store(_ picture: CGImage, attachment id: String) {
            lock.withLock { attachments[id] = picture }
        }
    }

    private struct Look {
        let symbol: String
        let top: UIColor
        let bottom: UIColor
    }

    private static let looks: [String: Look] = [
        "tram": Look(symbol: "tram.fill", top: UIColor(red: 0.98, green: 0.78, blue: 0.25, alpha: 1), bottom: UIColor(red: 0.85, green: 0.35, blue: 0.18, alpha: 1)),
        "sunset": Look(symbol: "sun.horizon.fill", top: UIColor(red: 0.98, green: 0.55, blue: 0.35, alpha: 1), bottom: UIColor(red: 0.45, green: 0.22, blue: 0.55, alpha: 1)),
        "pastry": Look(symbol: "birthday.cake.fill", top: UIColor(red: 0.99, green: 0.86, blue: 0.62, alpha: 1), bottom: UIColor(red: 0.80, green: 0.55, blue: 0.30, alpha: 1)),
        "tiles": Look(symbol: "square.grid.3x3.fill", top: UIColor(red: 0.30, green: 0.55, blue: 0.85, alpha: 1), bottom: UIColor(red: 0.12, green: 0.25, blue: 0.55, alpha: 1)),
        "river": Look(symbol: "water.waves", top: UIColor(red: 0.55, green: 0.80, blue: 0.95, alpha: 1), bottom: UIColor(red: 0.15, green: 0.40, blue: 0.60, alpha: 1)),
        "palace": Look(symbol: "building.columns.fill", top: UIColor(red: 0.70, green: 0.85, blue: 0.60, alpha: 1), bottom: UIColor(red: 0.25, green: 0.50, blue: 0.35, alpha: 1)),
        "dinner": Look(symbol: "fork.knife", top: UIColor(red: 0.95, green: 0.62, blue: 0.40, alpha: 1), bottom: UIColor(red: 0.62, green: 0.25, blue: 0.20, alpha: 1)),
        "seafood": Look(symbol: "fish.fill", top: UIColor(red: 0.45, green: 0.80, blue: 0.80, alpha: 1), bottom: UIColor(red: 0.10, green: 0.42, blue: 0.50, alpha: 1)),
        "guitar": Look(symbol: "guitars.fill", top: UIColor(red: 0.55, green: 0.45, blue: 0.80, alpha: 1), bottom: UIColor(red: 0.20, green: 0.15, blue: 0.40, alpha: 1)),
    ]

    /// 1,200 pixels wide: the text view treats pixels as points and scales
    /// an image down to the column, so this stays sharp on a 3× screen.
    private static func draw(_ name: String) -> CGImage {
        let look = looks[name] ?? Look(symbol: "photo", top: .systemTeal, bottom: .systemIndigo)
        let size = CGSize(width: 1200, height: 800)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let colors = [look.top.cgColor, look.bottom.cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width * 0.4, y: size.height),
                                                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            // Soft circles, so it reads as a picture rather than a swatch.
            for index in 0..<6 {
                let radius = CGFloat(80 + index * 45)
                let center = CGPoint(x: CGFloat((index * 397) % 1200), y: CGFloat((index * 251) % 800))
                UIColor.white.withAlphaComponent(0.08).setFill()
                UIBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
            }
            let configuration = UIImage.SymbolConfiguration(pointSize: 300, weight: .regular)
            if let symbol = UIImage(systemName: look.symbol, withConfiguration: configuration)?.withTintColor(.white, renderingMode: .alwaysOriginal) {
                let box = CGRect(x: (size.width - symbol.size.width) / 2, y: (size.height - symbol.size.height) / 2,
                                 width: symbol.size.width, height: symbol.size.height)
                symbol.draw(in: box, blendMode: .normal, alpha: 0.92)
            }
        }
        return image.cgImage!
    }
}
