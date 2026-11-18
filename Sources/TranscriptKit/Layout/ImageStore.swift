import CoreGraphics
import Foundation

/// Loads the pictures for images in the text with the loader the app gave
/// the view, and keeps them. Any thread.
///
/// Nothing is fetched unless the app sets a loader: an image URL written by
/// a model can carry data out of the conversation when it is fetched.
final class TranscriptImageStore: @unchecked Sendable {
    typealias Loader = @Sendable (TranscriptImage) async -> CGImage?

    private let lock = NSLock()
    private var pictures: [String: CGImage] = [:]
    private var requested: Set<String> = []
    private var loader: Loader?
    private var onChange: (@Sendable () -> Void)?
    private var generation = 0
    private var _revision = 0

    /// Goes up each time a picture arrives; layouts made at an older
    /// revision may show placeholders where pictures now are.
    var revision: Int { lock.withLock { _revision } }

    /// Sets the loader and what to call (on any thread) when a picture has
    /// arrived. Pictures loaded with an earlier loader are dropped, and the
    /// revision goes up so that images already laid out are asked for again.
    func setLoader(_ loader: Loader?, onChange: (@Sendable () -> Void)?) {
        lock.withLock {
            self.loader = loader
            self.onChange = onChange
            generation += 1
            _revision += 1
            pictures = [:]
            requested = []
        }
    }

    /// The picture for `image` if it has arrived. Starts loading it if not.
    func picture(for image: TranscriptImage) -> CGImage? {
        let (picture, load, generation): (CGImage?, Loader?, Int) = lock.withLock {
            if let picture = pictures[image.source] { return (picture, nil, self.generation) }
            guard let loader, !requested.contains(image.source) else { return (nil, nil, self.generation) }
            requested.insert(image.source)
            return (nil, loader, self.generation)
        }
        if let load {
            Task.detached { [weak self] in
                let box = PictureBox(picture: await load(image))
                self?.finish(image.source, box, generation: generation)
            }
        }
        return picture
    }

    private func finish(_ source: String, _ box: PictureBox, generation: Int) {
        let handler: (@Sendable () -> Void)? = lock.withLock {
            guard generation == self.generation, let picture = box.picture else { return nil }
            pictures[source] = picture
            _revision += 1
            return onChange
        }
        handler?()
    }
}

/// CGImage is immutable, so it is safe to hand between threads.
private struct PictureBox: @unchecked Sendable {
    let picture: CGImage?
}
