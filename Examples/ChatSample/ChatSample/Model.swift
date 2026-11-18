import SwiftUI
import TranscriptKit
import UIKit

/// A run of Markdown in an assistant's answer.
///
/// While it streams, chunks go to `stream`, which hands them to the text view
/// directly: SwiftUI hears nothing until the segment finishes. That is what
/// keeps a long answer cheap to stream, so nothing here that changes per
/// chunk is observed. Once finished, the segment is a plain document.
@MainActor
@Observable
final class TextSegment: Identifiable {
    let id = UUID()
    @ObservationIgnored private(set) var stream: TranscriptStream?
    /// Set once the segment is complete.
    private(set) var document: TranscriptDocument?
    /// The Markdown so far, for Copy and Share. Not observed: it changes with every chunk.
    @ObservationIgnored private(set) var markdown = ""

    /// A segment that is about to stream.
    init() {
        stream = TranscriptStream(tags: SampleTags.all)
    }

    /// A segment that is already complete, such as earlier messages.
    init(markdown: String) {
        self.markdown = markdown
        document = MarkdownStreamParser.document(from: markdown, tags: SampleTags.all)
    }

    func append(_ chunk: String) {
        markdown += chunk
        stream?.append(chunk)
    }

    /// Shows anything held back while it could still become markup, and
    /// swaps the stream for the finished document.
    func finish() {
        guard let stream, document == nil else { return }
        stream.finish()
        stream.flush()
        document = stream.document
    }
}

/// Sample data shown in native cards between text segments.
struct Forecast {
    struct Day: Identifiable {
        let id = UUID()
        let name: String
        let symbol: String
        let high: Int
        let low: Int
    }

    let city: String
    let summary: String
    let temperature: Int
    let symbol: String
    let days: [Day]
}

struct SalesChart {
    struct Point: Identifiable {
        var id: String { quarter }
        let quarter: String
        let revenue: Double
        let orders: Int
    }

    let points: [Point]
}

struct Source: Identifiable {
    let id = UUID()
    let title: String
    let url: URL
    let symbol: String
}

/// A restaurant row: a photo, Markdown about it, and a save button.
struct Place: Identifiable {
    let id = UUID()
    /// A `sample://photo/` name.
    let photo: String
    let text: TextSegment

    @MainActor init(photo: String, markdown: String) {
        self.photo = photo
        self.text = TextSegment(markdown: markdown)
    }
}

/// One column of a side-by-side comparison.
struct ComparisonColumn: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String
    let text: TextSegment

    @MainActor init(title: String, symbol: String, markdown: String) {
        self.title = title
        self.symbol = symbol
        self.text = TextSegment(markdown: markdown)
    }
}

/// One stop of a day plan: a time beside Markdown.
struct TimelineEntry: Identifiable {
    let id = UUID()
    let time: String
    let text: TextSegment

    @MainActor init(time: String, markdown: String) {
        self.time = time
        self.text = TextSegment(markdown: markdown)
    }
}

/// A picture the user attached.
struct Attachment: Identifiable {
    let id: String
    let image: UIImage
}

/// One piece of an assistant's answer.
struct Part: Identifiable {
    enum Content {
        case text(TextSegment)
        /// Tool progress, shown until the tool's result replaces it.
        case status(String)
        case weather(Forecast)
        case chart(SalesChart)
        /// Generated pictures, by `sample://photo/` name.
        case photos([String])
        case sources([Source])
        // Native layouts with TranscriptKit text beside other views.
        /// An icon beside text that streams.
        case callout(symbol: String, text: TextSegment)
        case places([Place])
        case comparison([ComparisonColumn])
        case timeline([TimelineEntry])

        /// The TranscriptKit text in this part, in reading order.
        var segments: [TextSegment] {
            switch self {
            case .text(let segment), .callout(_, let segment): [segment]
            case .places(let places): places.map(\.text)
            case .comparison(let columns): columns.map(\.text)
            case .timeline(let entries): entries.map(\.text)
            case .status, .weather, .chart, .photos, .sources: []
            }
        }
    }

    let id = UUID()
    var content: Content
}

@MainActor
@Observable
final class Message: Identifiable {
    enum Role {
        case user
        case assistant
    }

    enum Rating {
        case good
        case bad
    }

    let id = UUID()
    let role: Role
    /// The user's words.
    var text: String
    var attachments: [Attachment]
    /// The assistant's answer: text segments and native parts, in order.
    var parts: [Part] = []
    var isStreaming = false
    /// The user stopped the answer before it finished.
    var wasStopped = false
    var suggestions: [String] = []
    var rating: Rating?
    /// The prompt this answer is for, to regenerate it.
    var prompt = ""

    init(role: Role, text: String = "", attachments: [Attachment] = []) {
        self.role = role
        self.text = text
        self.attachments = attachments
    }

    /// The answer's text as Markdown, for Copy and Share: every TranscriptKit
    /// segment, including those inside native parts.
    var markdown: String {
        if role == .user { return text }
        return parts.flatMap(\.content.segments).map(\.markdown).joined(separator: "\n\n")
    }

    /// Shows the rest of any text still streaming, such as after Stop.
    func finishText() {
        for part in parts {
            for segment in part.content.segments { segment.finish() }
        }
    }

    /// The text segment being written, if the last part is one.
    var streamingSegment: TextSegment? {
        guard let last = parts.last, case .text(let segment) = last.content, segment.document == nil else { return nil }
        return segment
    }
}
