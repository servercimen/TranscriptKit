import PhotosUI
import SafariServices
import SwiftUI

struct ChatView: View {
    @Bindable var conversation: Conversation
    @State private var draft = ""
    @State private var attachments: [Attachment] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var openedLink: OpenedLink?
    @FocusState private var composerFocused: Bool
    @AppStorage(TranscriptHighlight.key) private var highlightsTranscriptViews = TranscriptHighlight.default
    /// Taps on the sparkles button, which plays tags waiting to animate.
    @State private var tagPlayRequests = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                // Not a LazyVStack: in a scroll view anchored at the bottom,
                // a lazy stack stopped drawing once an answer started to grow
                // (iOS 27 simulator). A plain stack builds every message, which
                // is fine for a conversation of this size.
                VStack(alignment: .leading, spacing: 24) {
                    if conversation.messages.isEmpty {
                        EmptyState { conversation.send($0) }
                    }
                    ForEach(conversation.messages) { message in
                        MessageView(message: message, conversation: conversation)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            // Keeps the end of a growing answer in view.
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) { composer }
            .overlay(alignment: .top) { toast }
            .navigationTitle("Assistant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Toggle(isOn: $highlightsTranscriptViews) {
                        Label("Highlight TranscriptKit views", systemImage: "highlighter")
                    }
                    .toggleStyle(.button)
                }
                if SampleTiming.timing.contains(.whenRequested) {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Play highlights", systemImage: "sparkles") { tagPlayRequests += 1 }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New chat", systemImage: "square.and.pencil") { conversation.startOver() }
                }
            }
            .environment(\.tagPlayRequests, tagPlayRequests)
            // Links in the text, the source cards and the composer all come here.
            .environment(\.openURL, OpenURLAction { url in
                // A `<mention>`'s link (see `SampleTags`).
                if url.scheme == "sample", url.host() == "person" {
                    withAnimation { conversation.showToast("\(url.lastPathComponent.capitalized)'s profile") }
                    return .handled
                }
                guard url.scheme == "http" || url.scheme == "https" else { return .systemAction }
                openedLink = OpenedLink(url: url)
                return .handled
            })
            .sheet(item: $openedLink) { SafariView(url: $0.url).ignoresSafeArea() }
        }
        .onChange(of: pickerItems) { _, items in Task { await load(items) } }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 8) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { attachment in
                            Image(uiImage: attachment.image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(alignment: .topTrailing) {
                                    Button {
                                        attachments.removeAll { $0.id == attachment.id }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, .black.opacity(0.6))
                                    }
                                    .padding(4)
                                    .accessibilityLabel("Remove photo")
                                }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                PhotosPicker(selection: $pickerItems, maxSelectionCount: 4, matching: .images) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.title3)
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel("Attach photos")
                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($composerFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
                if conversation.isResponding {
                    Button { conversation.stop() } label: {
                        Image(systemName: "stop.circle.fill").font(.system(size: 32))
                    }
                    .accessibilityLabel("Stop")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
                    .accessibilityLabel("Send")
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func send() {
        conversation.send(draft, attachments: attachments)
        draft = ""
        attachments = []
        pickerItems = []
    }

    private func load(_ items: [PhotosPickerItem]) async {
        var loaded: [Attachment] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else { continue }
            loaded.append(SampleImages.attach(image))
        }
        attachments = loaded
    }

    @ViewBuilder
    private var toast: some View {
        if let text = conversation.toast {
            Label(text, systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// What a new chat shows: a few prompts to start from.
private struct EmptyState: View {
    let send: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.largeTitle)
                .foregroundStyle(.tint)
            Text("Ask about a trip, some numbers or a photo.")
                .font(.title3.weight(.semibold))
            ForEach(Script.starterPrompts, id: \.self) { prompt in
                Button { send(prompt) } label: {
                    Label(prompt, systemImage: "arrow.up.right")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.top, 40)
    }
}

private struct OpenedLink: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
