import SwiftUI

// Native layouts that put TranscriptKit text beside other views in an
// `HStack`. The text view takes the width its neighbors leave and reports
// its height for that width, so rows grow with the text, including while it
// streams.

// MARK: Callout

/// An icon beside text that streams in.
struct CalloutCard: View {
    let symbol: String
    let text: TextSegment

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Color.orange.gradient, in: Circle())
                .accessibilityHidden(true)
            SegmentText(segment: text, style: .compact)
        }
        .card()
    }
}

// MARK: Places

/// Rows of a photo, Markdown and a save button.
struct PlacesList: View {
    let places: [Place]
    @State private var saved: Set<Place.ID> = []

    var body: some View {
        VStack(spacing: 0) {
            ForEach(places) { place in
                HStack(alignment: .top, spacing: 12) {
                    Image(uiImage: SampleImages.photo(place.photo))
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .accessibilityHidden(true)
                    SegmentText(segment: place.text, style: .compact)
                    Button {
                        withAnimation(.snappy) {
                            if saved.contains(place.id) { saved.remove(place.id) } else { saved.insert(place.id) }
                        }
                    } label: {
                        Image(systemName: saved.contains(place.id) ? "bookmark.fill" : "bookmark")
                            .font(.title3)
                            .frame(width: 32, height: 32)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .accessibilityLabel(saved.contains(place.id) ? "Saved" : "Save")
                }
                .padding(.vertical, 12)
                if place.id != places.last?.id {
                    Divider().padding(.leading, 76)
                }
            }
        }
        .padding(.horizontal, 14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: Comparison

/// Two text views side by side, split by a divider.
struct ComparisonCard: View {
    let columns: [ComparisonColumn]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(columns) { column in
                VStack(alignment: .leading, spacing: 8) {
                    Label(column.title, systemImage: column.symbol)
                        .font(.subheadline.weight(.semibold))
                    SegmentText(segment: column.text, style: .compact)
                }
                // Equal columns, whatever the length of their text.
                .frame(maxWidth: .infinity, alignment: .leading)
                if column.id != columns.last?.id {
                    Divider()
                }
            }
        }
        .card()
    }
}

// MARK: Timeline

/// Times down the left, a line with dots, and text beside each time.
struct TimelineList: View {
    let entries: [TimelineEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(entries) { entry in
                let isLast = entry.id == entries.last?.id
                HStack(alignment: .top, spacing: 10) {
                    Text(entry.time)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .trailing)
                        .padding(.top, 1)
                    VStack(spacing: 0) {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 10, height: 10)
                            .padding(.top, 5)
                        // Runs down to the next stop, however tall this text is.
                        Rectangle()
                            .fill(isLast ? Color.clear : Color(.separator))
                            .frame(width: 2)
                            .frame(maxHeight: .infinity)
                    }
                    SegmentText(segment: entry.text, style: .compact)
                        .padding(.bottom, isLast ? 0 : 16)
                }
                // The row is as tall as its text; the line fills that height.
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
