import Charts
import SwiftUI

/// A tool at work.
struct StatusRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

/// A card style shared by the native parts.
private struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}

// MARK: Weather

struct WeatherCard: View {
    let forecast: Forecast

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: forecast.symbol)
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 40))
                VStack(alignment: .leading, spacing: 2) {
                    Text(forecast.city).font(.headline)
                    Text("\(forecast.temperature)° · \(forecast.summary)").foregroundStyle(.secondary)
                }
                Spacer()
                Text("Sample data")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color(.tertiarySystemFill), in: Capsule())
            }
            Divider()
            HStack {
                ForEach(forecast.days) { day in
                    VStack(spacing: 6) {
                        Text(day.name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Image(systemName: day.symbol).symbolRenderingMode(.multicolor).font(.title3)
                        Text("\(day.high)° / \(day.low)°").font(.caption).monospacedDigit()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .card()
        .accessibilityElement(children: .combine)
    }
}

// MARK: Chart

struct SalesChartCard: View {
    enum Measure: String, CaseIterable, Identifiable {
        case revenue = "Revenue"
        case orders = "Orders"
        var id: String { rawValue }
    }

    let chart: SalesChart
    @State private var measure = Measure.revenue
    /// The quarter whose figures are shown: the last one tapped.
    @State private var selected: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("By quarter").font(.headline)
                Spacer()
                Picker("Measure", selection: $measure) {
                    ForEach(Measure.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            Chart(chart.points) { point in
                BarMark(x: .value("Quarter", point.quarter), y: .value(measure.rawValue, value(of: point)))
                    .foregroundStyle(selected == nil || selected == point.quarter ? Color.accentColor : Color.accentColor.opacity(0.35))
                    .cornerRadius(5)
                if selected == point.quarter {
                    RuleMark(x: .value("Quarter", point.quarter))
                        .foregroundStyle(.clear)
                        .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit, y: .disabled)) {
                            Text(label(of: point))
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.background, in: Capsule())
                                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                        }
                }
            }
            // A tap picks the quarter under it. (`chartXSelection` wants a
            // press and drag, which the scroll view around it takes first.)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { location in
                            guard let plot = proxy.plotFrame else { return }
                            let x = location.x - geometry[plot].origin.x
                            if let quarter: String = proxy.value(atX: x) {
                                withAnimation(.snappy) { selected = selected == quarter ? nil : quarter }
                            }
                        }
                }
            }
            .frame(height: 180)
            // Room above the tallest bar for its label.
            .padding(.top, 22)
            .animation(.snappy, value: measure)
            Text("Sample data · tap a bar")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .card()
    }

    private func value(of point: SalesChart.Point) -> Double {
        measure == .revenue ? point.revenue : Double(point.orders)
    }

    private func label(of point: SalesChart.Point) -> String {
        measure == .revenue ? String(format: "$%.2fM", point.revenue) : "\(point.orders.formatted()) orders"
    }
}

// MARK: Photos

struct PhotoStrip: View {
    let names: [String]
    @State private var opened: OpenedPhoto?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(names, id: \.self) { name in
                    Button { opened = OpenedPhoto(name: name) } label: {
                        Image(uiImage: SampleImages.photo(name))
                            .resizable()
                            .scaledToFill()
                            .frame(width: 150, height: 100)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Photo: \(name)")
                }
            }
        }
        .scrollClipDisabled()
        .fullScreenCover(item: $opened) { photo in
            PhotoViewer(name: photo.name)
        }
    }
}

private struct OpenedPhoto: Identifiable {
    let name: String
    var id: String { name }
}

private struct PhotoViewer: View {
    let name: String
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            Image(uiImage: SampleImages.photo(name))
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .gesture(MagnifyGesture().onChanged { scale = max(1, $0.magnification) }.onEnded { _ in withAnimation { scale = 1 } })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .white.opacity(0.25))
            }
            .padding()
            .accessibilityLabel("Close")
        }
    }
}

// MARK: Sources

struct SourcesRow: View {
    let sources: [Source]
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sources").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                        Button { openURL(source.url) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: source.symbol)
                                    .frame(width: 28, height: 28)
                                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(source.title).font(.subheadline).lineLimit(1)
                                    Text("\(index + 1) · \(source.url.host() ?? "")").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollClipDisabled()
        }
    }
}
