import SwiftUI

@main
struct ChatSampleApp: App {
    @State private var conversation = Conversation.sample()

    var body: some Scene {
        WindowGroup {
            ChatView(conversation: conversation)
                .task { await runLaunchArguments() }
        }
    }

    /// For trying the app from the command line:
    /// `-prompt "Analyze our quarterly sales"` sends a prompt after launch,
    /// `-attachSample 1` attaches a generated photo to it,
    /// `-startEmpty 1` starts with no conversation, and `-slow 1` streams
    /// answers four times slower.
    private func runLaunchArguments() async {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "startEmpty") { conversation.startOver() }
        guard let prompt = defaults.string(forKey: "prompt") else { return }
        try? await Task.sleep(for: .seconds(1))
        var attachments: [Attachment] = []
        if defaults.bool(forKey: "attachSample") {
            attachments.append(SampleImages.attach(SampleImages.samplePhoto()))
        }
        conversation.send(prompt, attachments: attachments)
    }
}
