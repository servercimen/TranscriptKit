import SwiftUI
import TranscriptKit

struct MessageView: View {
    let message: Message
    let conversation: Conversation

    var body: some View {
        switch message.role {
        case .user: UserBubble(message: message)
        case .assistant: AssistantMessageView(message: message, conversation: conversation)
        }
    }
}

// MARK: User

private struct UserBubble: View {
    let message: Message

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !message.attachments.isEmpty {
                HStack(spacing: 6) {
                    ForEach(message.attachments) { attachment in
                        Image(uiImage: attachment.image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: message.attachments.count == 1 ? 200 : 96,
                                   height: message.attachments.count == 1 ? 140 : 96)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .accessibilityLabel("Attached photo")
                    }
                }
            }
            if !message.text.isEmpty {
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .foregroundStyle(.white)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18))
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 48)
    }
}

// MARK: Assistant

private struct AssistantMessageView: View {
    let message: Message
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Color.accentColor.gradient, in: Circle())
                Text("Assistant").font(.subheadline.weight(.semibold))
                if message.isStreaming, message.parts.isEmpty {
                    ProgressView().controlSize(.small)
                }
            }
            ForEach(message.parts) { part in
                PartView(part: part)
            }
            if message.wasStopped {
                Label("Stopped", systemImage: "stop.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            // A stopped answer keeps its bar even when empty, for Regenerate.
            if !message.isStreaming, !message.parts.isEmpty || message.wasStopped {
                ActionBar(message: message, conversation: conversation)
            }
            if !message.isStreaming, !message.suggestions.isEmpty {
                SuggestionChips(suggestions: message.suggestions) { conversation.send($0) }
            }
        }
    }
}

private struct PartView: View {
    let part: Part

    var body: some View {
        switch part.content {
        case .text(let segment): SegmentText(segment: segment)
        case .status(let text): StatusRow(text: text)
        case .weather(let forecast): WeatherCard(forecast: forecast)
        case .chart(let chart): SalesChartCard(chart: chart)
        case .photos(let names): PhotoStrip(names: names)
        case .sources(let sources): SourcesRow(sources: sources)
        case .callout(let symbol, let text): CalloutCard(symbol: symbol, text: text)
        case .places(let places): PlacesList(places: places)
        case .comparison(let columns): ComparisonCard(columns: columns)
        case .timeline(let entries): TimelineList(entries: entries)
        }
    }
}

/// One text segment, drawn by TranscriptKit: selectable, with tappable links
/// and Markdown images from the app's loader.
///
/// It takes all the width it is offered and is as tall as its text at that
/// width. In an `HStack` it shares the space left by its fixed-size
/// neighbors like any flexible view; it doesn't shrink to short text.
struct SegmentText: View {
    let segment: TextSegment
    var style = TranscriptStyle.chat
    @AppStorage(TranscriptHighlight.key) private var highlighted = TranscriptHighlight.default
    @Environment(\.tagPlayRequests) private var playRequests

    var body: some View {
        text
            .imageLoader(SampleImages.loader)
            .tagAnimationTiming(SampleTiming.timing)
            .playTagAnimations(trigger: playRequests)
            .background { if highlighted { TranscriptHighlight() } }
    }

    /// One `TranscriptText` whether streaming or finished, so SwiftUI updates
    /// the existing text view when the stream ends instead of replacing it.
    private var text: TranscriptText {
        if let document = segment.document {
            return TranscriptText(document, style: style)
        }
        return TranscriptText(stream: segment.stream ?? TranscriptStream(), style: style)
    }
}

/// Marks where each TranscriptKit view is, to tell them apart from the
/// native SwiftUI parts around them. The text view is transparent, so this
/// shows through it. Turned on and off from the toolbar.
struct TranscriptHighlight: View {
    static let key = "highlightTranscriptViews"
    static let `default` = true

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        shape
            .fill(Color.yellow.opacity(0.22))
            .overlay(shape.strokeBorder(Color.orange.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [5, 3])))
            // A little outside the text, so the outline doesn't touch it.
            .padding(-4)
    }
}

extension TranscriptStyle {
    static var chat: TranscriptStyle {
        var style = TranscriptStyle()
        style.bodySize = 16.5
        style.blockSpacing = 12
        style.maximumImageHeight = 240
        return style
    }

    /// For text inside rows and cards: a little smaller and tighter.
    static var compact: TranscriptStyle {
        var style = TranscriptStyle.chat
        style.bodySize = 15
        style.lineSpacing = 2
        style.blockSpacing = 6
        style.listItemSpacing = 3
        style.listIndent = 18
        return style
    }
}

private struct ActionBar: View {
    let message: Message
    let conversation: Conversation

    var body: some View {
        HStack(spacing: 18) {
            if !message.parts.isEmpty {
                Button {
                    UIPasteboard.general.string = message.markdown
                    withAnimation { conversation.showToast("Copied") }
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .accessibilityLabel("Copy")
                ShareLink(item: message.markdown) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share")
                Button {
                    message.rating = message.rating == .good ? nil : .good
                } label: {
                    Image(systemName: message.rating == .good ? "hand.thumbsup.fill" : "hand.thumbsup")
                }
                .accessibilityLabel("Good answer")
                Button {
                    message.rating = message.rating == .bad ? nil : .bad
                } label: {
                    Image(systemName: message.rating == .bad ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                }
                .accessibilityLabel("Bad answer")
            }
            if conversation.messages.last === message {
                Button { conversation.regenerate(message) } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Regenerate")
            }
            Spacer()
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .buttonStyle(.plain)
    }
}

private struct SuggestionChips: View {
    let suggestions: [String]
    let send: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button(suggestion) { send(suggestion) }
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color(.secondarySystemBackground), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color(.separator), lineWidth: 0.5))
                        .buttonStyle(.plain)
                }
            }
        }
    }
}
