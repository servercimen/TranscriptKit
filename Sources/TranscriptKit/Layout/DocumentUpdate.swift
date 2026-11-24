import Foundation

/// How a view takes a document that the app sets directly.
enum DocumentUpdate: Equatable {
    /// Laid out on the layout queue, as each update of a stream is. The
    /// view shows the old layout until the new one is ready.
    case background
    /// Laid out on the main thread at once, so the view's size is the new
    /// one before the app measures it. The view crossfades from the old
    /// drawing for this many seconds, or shows the new one at once for zero.
    case now(crossfade: TimeInterval)

    /// What the view does when the app replaces `old` with `new`.
    ///
    /// - Parameters:
    ///   - isLaidOut: the view shows a layout and has a width, so it can
    ///     lay out the new document now.
    ///   - crossfade: the view's `replacementCrossfadeDuration`. Nil keeps
    ///     every document on the background path.
    /// - Returns: `.now` only for a document that does not add to `old`. A
    ///   document that adds to it (longer text in the last block, or more
    ///   blocks) goes to the background, as a stream's updates do. So does
    ///   the first text after an empty document.
    static func choose(replacing old: TranscriptDocument, with new: TranscriptDocument, isLaidOut: Bool,
                       crossfade: TimeInterval?) -> DocumentUpdate {
        guard isLaidOut, let crossfade, !new.extends(old) else { return .background }
        return .now(crossfade: max(crossfade, 0))
    }
}
