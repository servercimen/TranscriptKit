import Foundation

/// A colored stretch of a code block, from the app's highlighter; see
/// `TranscriptTextView.codeHighlighter`.
public struct TranscriptCodeHighlight: Equatable, Sendable {
    /// UTF-16 offsets in the code block's text.
    public var range: Range<Int>
    public var color: TranscriptColor
    /// `.bold` and `.italic` are used; other traits are ignored.
    public var traits: InlineSpan.Traits

    public init(range: Range<Int>, color: TranscriptColor, traits: InlineSpan.Traits = []) {
        self.range = range
        self.color = color
        self.traits = traits
    }
}

/// Colors the code of a code block: its text and the fence's language, or
/// nil. Called off the main thread, at most once at a time for each block.
public typealias TranscriptCodeHighlighter = @Sendable (_ code: String, _ language: String?) async -> [TranscriptCodeHighlight]
