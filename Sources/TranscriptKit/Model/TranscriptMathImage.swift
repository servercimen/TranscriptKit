import CoreGraphics
import Foundation

/// A formula drawn by the app's renderer; see `TranscriptTextView.mathRenderer`.
public struct TranscriptMathImage: @unchecked Sendable {
    /// A mask: only its alpha is used, and it is drawn in the text color, so
    /// the formula follows light and dark appearance.
    public var image: CGImage
    /// Its size, in points. A formula wider than the text column is scaled down to fit.
    public var size: CGSize
    /// How far the formula's baseline is above its bottom edge, in points:
    /// its depth. The baseline sits on the line's baseline.
    public var baseline: CGFloat

    public init(image: CGImage, size: CGSize, baseline: CGFloat) {
        self.image = image
        self.size = size
        self.baseline = max(baseline, 0)
    }
}

/// Draws a formula at a font size: the size of the text around inline math,
/// or of the paragraph for display math. Called off the main thread, once
/// for each formula and size in a `TranscriptMathCache`, and again only if
/// the cache removed the formula. Nil shows the LaTeX as written.
public typealias TranscriptMathRenderer = @Sendable (_ math: TranscriptMath, _ fontSize: CGFloat) async -> TranscriptMathImage?

extension TranscriptMathImage {
    /// The formula with its image's alpha as a DeviceGray image without
    /// alpha: the only kind of image that `CGContext.clip(to:mask:)` takes.
    func withAlphaAsMask() -> TranscriptMathImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue),
              let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let provider = CGDataProvider(data: Data(bytes: data, count: context.bytesPerRow * height) as CFData),
              let mask = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: context.bytesPerRow,
                                 space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                 provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return TranscriptMathImage(image: mask, size: size, baseline: baseline)
    }
}
