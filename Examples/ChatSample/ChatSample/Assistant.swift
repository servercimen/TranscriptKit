import SwiftUI

/// The sample has no model behind it: answers are scripts, played out over
/// time the way a model streams text and calls tools.
enum Script {
    enum Step {
        /// A tool is working; shown until the next part arrives.
        case status(String)
        case pause(Duration)
        /// Markdown, streamed a few characters at a time.
        case text(String)
        /// A native part between text segments.
        case part(Part.Content)
        /// A native part with TranscriptKit text inside it. It is made when
        /// it is shown, so each answer gets text of its own.
        case layout(@MainActor @Sendable () -> Part.Content)
        /// An icon beside Markdown that streams.
        case callout(symbol: String, markdown: String)
        case suggestions([String])
    }

    static func steps(for prompt: String, attachments: [Attachment]) -> [Step] {
        let lowered = prompt.lowercased()
        if lowered.contains("caption") { return caption }
        if !attachments.isEmpty || lowered.contains("photo") { return photo(attachments) }
        if lowered.contains("q3") || lowered.contains("jump") { return q3 }
        if lowered.contains("sales") || lowered.contains("revenue") || lowered.contains("analy") { return sales }
        if lowered.contains("cheaper") { return cheaper }
        if lowered.contains("sintra") { return sintra }
        let words = Set(lowered.split { !$0.isLetter }.map(String.init))
        if !words.isDisjoint(with: ["eat", "dinner", "lunch", "restaurant", "restaurants", "food"]) { return dinner }
        if !words.isDisjoint(with: ["team", "ship", "shipped", "tags"]) { return team }
        if lowered.contains("lisbon") || lowered.contains("weekend") || lowered.contains("trip") { return lisbon }
        return fallback
    }

    static let starterPrompts = [
        "Plan a weekend in Lisbon", "Where should we eat?", "What did the team ship?", "Analyze our quarterly sales",
        "What's in this photo?",
    ]

    // MARK: Scripts

    static let lisbon: [Step] = [
        .status("Checking the forecast for Lisbon…"),
        .pause(.milliseconds(900)),
        .part(.weather(Forecast(
            city: "Lisbon", summary: "Mostly sunny", temperature: 21, symbol: "sun.max.fill",
            days: [
                .init(name: "Fri", symbol: "sun.max.fill", high: 22, low: 14),
                .init(name: "Sat", symbol: "cloud.sun.fill", high: 21, low: 15),
                .init(name: "Sun", symbol: "sun.max.fill", high: 23, low: 15),
            ]
        ))),
        .text("""
        ## A weekend in Lisbon

        The forecast looks **mild and dry**, so here is a plan that keeps you outdoors. Budgets are rough figures per person (sample data).

        | Day | Plan | Budget |
        | :--- | :--- | ---: |
        | Saturday | Alfama on foot, tram 28, *Miradouro da Graça* at sunset | €45 |
        | Sunday | Belém in the morning, LX Factory after lunch | €60 |

        ![Tram 28 climbing through Alfama](sample://photo/tram)

        ### Before you go

        - [x] Book the flights
        - [ ] Reserve dinner for Saturday
        - [ ] Buy a *Viva Viagem* card at the airport

        > Trams fill up by 10 a.m. Start early, or walk up the hill and ride down.
        """),
        .part(.photos(["sunset", "pastry", "tiles", "river"])),
        .text("""
        Pastries in Belém sell out by noon, so go there first on Sunday. For bookings, write to trips@example.com or see the [city guide](https://example.com/lisbon) [1].

        [1]: https://example.com/lisbon/transport "Getting around"
        """),
        .part(.sources([
            Source(title: "Lisbon city guide", url: URL(string: "https://example.com/lisbon")!, symbol: "map"),
            Source(title: "Getting around by tram", url: URL(string: "https://example.com/lisbon/transport")!, symbol: "tram"),
            Source(title: "Weekend forecast", url: URL(string: "https://example.com/weather/lisbon")!, symbol: "cloud.sun"),
        ])),
        .suggestions(["Where should we eat?", "Add a day trip to Sintra", "Make it cheaper", "Analyze our quarterly sales"]),
    ]

    /// TranscriptKit text beside other views: photos and buttons, an icon,
    /// another text view.
    static let dinner: [Step] = [
        .status("Looking for restaurants near Alfama…"),
        .pause(.milliseconds(900)),
        .text("""
        Three places within a short walk of Alfama. The restaurants are made up (sample data); tap the bookmark to save one.
        """),
        .layout {
            .places([
                Place(photo: "dinner", markdown: """
                **Tasca do Miradouro** · €€ · ★\u{00A0}4.6\\
                Small plates (*petiscos*) and vinho verde on a terrace. [Menu](https://example.com/tasca)
                """),
                Place(photo: "seafood", markdown: """
                **Casa da Sardinha** · €€€ · ★\u{00A0}4.4\\
                Grilled fish by the weight; ask for the ~~set menu~~ catch of the day.
                """),
                Place(photo: "guitar", markdown: """
                **Fado na Esquina** · €€€ · ★\u{00A0}4.8\\
                Dinner with live *fado* from 9\u{00A0}p.m. Book at fado@example.com.
                """),
            ])
        },
        .callout(symbol: "lightbulb.max.fill", markdown: """
        Dinner starts late in Lisbon: most kitchens open around **7:30 p.m.** and fill up after 9. Book the *fado* place a day ahead.
        """),
        .text("How the two most popular compare:"),
        .layout {
            .comparison([
                ComparisonColumn(title: "Tasca", symbol: "fork.knife", markdown: """
                - About **€25** a person
                - Terrace with a view
                - No booking before 8\u{00A0}p.m.
                """),
                ComparisonColumn(title: "Fado", symbol: "music.note", markdown: """
                - About **€45** with the show
                - Live music from 9\u{00A0}p.m.
                - Book a day ahead
                """),
            ])
        },
        .suggestions(["Add a day trip to Sintra", "Analyze our quarterly sales"]),
    ]

    /// Custom tags (see `SampleTags`): mentions, highlights, status labels
    /// whose color comes from an attribute, and a redefined `<kbd>`.
    static let team: [Step] = [
        .status("Reading this week's updates…"),
        .pause(.milliseconds(800)),
        .text("""
        ## This week

        <mention id="ana">@Ana</mention> shipped the new search, and <mention id="bo">@Bo</mention> fixed the <hl>login timeouts that support flagged on Monday</hl>. Tap a name to open their profile (sample data).

        | Task | Owner | Status |
        | :-- | :-- | :-- |
        | New search | <mention id="ana">@Ana</mention> | <status value="done">Done</status> |
        | Login timeouts | <mention id="bo">@Bo</mention> | <status value="done">Done</status> |
        | Offline mode | <mention id="cy">@Cy</mention> | <status value="late">2 days late</status> |
        | Dark icons | <mention id="ana">@Ana</mention> | <status value="next">Next week</status> |

        > <mark>Offline mode is the one to watch:</mark> it blocks the release, and the sync fix <todo>still needs an owner</todo>.

        Try the new search with <kbd>⌘K</kbd>, or <kbd>⌘⇧F</kbd> to search every project. Tags the app doesn't define show as written, like <aside>this</aside>.
        """),
        .suggestions(["Where should we eat?", "Analyze our quarterly sales"]),
    ]

    static let sales: [Step] = [
        .status("Running the numbers…"),
        .pause(.milliseconds(1100)),
        .text("""
        Revenue grew in **every quarter** this year, with the biggest jump in Q3 (sample data). Tap a bar for its figures.
        """),
        .part(.chart(SalesChart(points: [
            .init(quarter: "Q1", revenue: 1.20, orders: 8_400),
            .init(quarter: "Q2", revenue: 1.34, orders: 9_100),
            .init(quarter: "Q3", revenue: 1.71, orders: 11_800),
            .init(quarter: "Q4", revenue: 1.86, orders: 12_300),
        ]))),
        .text("""
        | Quarter | Revenue | Growth |
        | :-- | --: | --: |
        | Q1 | $1.20M | – |
        | Q2 | $1.34M | +11.7% |
        | Q3 | $1.71M | +27.6% |
        | Q4 | $1.86M | +8.8% |

        The Q3 jump lines up with the launch campaign [2]. ~~Q2 was flat~~ Q2 grew by 11.7%, unlike the first draft of this report said.

        To reproduce the figures:

        ```sql
        SELECT quarter, SUM(amount) AS revenue
        FROM orders
        GROUP BY quarter
        ORDER BY quarter;
        ```

        1. Check that refunds are excluded
        1. Compare with last year's Q3
        1. Share the dashboard with the team

        [2]: https://example.com/reports/launch "Launch report"
        """),
        .suggestions(["Why did Q3 jump?", "Plan a weekend in Lisbon"]),
    ]

    static let q3: [Step] = [
        .status("Splitting revenue by customer…"),
        .pause(.milliseconds(900)),
        .text("""
        Most of the Q3 jump came from **new customers** (sample data):

        | Customers | Q2 | Q3 | Change |
        | :-- | --: | --: | --: |
        | Returning | $0.98M | $1.04M | +6% |
        | New | $0.36M | $0.67M | +86% |

        The new customers arrived in the three weeks after the launch campaign [2]. Returning customers grew at their usual pace.

        [2]: https://example.com/reports/launch "Launch report"
        """),
        .suggestions(["Plan a weekend in Lisbon"]),
    ]

    static func photo(_ attachments: [Attachment]) -> [Step] {
        let image: String
        let intro: String
        if let attachment = attachments.first {
            intro = "Here is what stands out in the photo:"
            image = "![Your photo, as the app's image loader gives it back](sample://attachment/\(attachment.id))"
        } else {
            intro = "You didn't attach a photo, so here is one of the sample pictures instead. (The photo button attaches your own.) What stands out:"
            image = "![A sample picture of a river](sample://photo/river)"
        }
        return [
            .status("Looking at the photo…"),
            .pause(.milliseconds(800)),
            .text("""
            \(intro)

            1. The light is soft and even, so the colors stay true.
            1. The subject sits in the middle, with room around it for a crop.
            1. The edges are a little dark; a light vignette fix would help.

            \(image)

            The second image below comes from an `https://` address. The app's loader only serves `sample://` images, so it shows its alt text instead of fetching anything:

            ![A chart on a remote server](https://example.com/charts/q3.png)
            """),
            .suggestions(["Suggest a caption", "Analyze our quarterly sales"]),
        ]
    }

    static let caption: [Step] = [
        .text("""
        A few captions, from plain to playful:

        1. *Afternoon by the water.*
        1. Proof that I **did** go outside this weekend.
        1. The quiet part of the trip.
        """),
        .suggestions(["Plan a weekend in Lisbon", "Analyze our quarterly sales"]),
    ]

    static let cheaper: [Step] = [
        .text("""
        To bring it **under €70 per person**:

        - Swap the tram for walking; Alfama is best on foot anyway
        - Have the *prato do dia* (dish of the day) at lunch, around €9
        - Skip LX Factory and spend Sunday afternoon at the river, which is free
        """),
        .suggestions(["Add a day trip to Sintra"]),
    ]

    static let sintra: [Step] = [
        .status("Checking trains…"),
        .pause(.milliseconds(700)),
        .text("""
        Trains to Sintra leave Rossio station **every 20 minutes** and take about 40 minutes. Go early; the palaces get busy by 11 a.m.

        ![The palace on the hill](sample://photo/palace)

        A plan for the day (sample times):
        """),
        .layout {
            .timeline([
                TimelineEntry(time: "8:40", markdown: "Train from **Rossio**. Sit on the left for the view."),
                TimelineEntry(time: "9:30", markdown: "Walk up to **Pena Palace**, about 40 minutes, or take the shuttle bus."),
                TimelineEntry(time: "12:30", markdown: "Lunch in the old town. Try a *travesseiro*, a local pastry."),
                TimelineEntry(time: "14:00", markdown: "**Quinta da Regaleira** and its well. Allow two hours."),
                TimelineEntry(time: "17:30", markdown: "Train back to Rossio. See the [timetable](https://example.com/sintra/trains)."),
            ])
        },
        .suggestions(["Where should we eat?", "Make it cheaper"]),
    ]

    static let fallback: [Step] = [
        .text("""
        I'm a scripted sample, so I only know a few answers. Try one of these:

        - **Plan a weekend in Lisbon**: a weather card, a table, a task list, photos and sources
        - **Where should we eat?**: text beside photos, buttons, an icon and another text view
        - **What did the team ship?**: custom tags for mentions, highlights and status labels
        - **Analyze our quarterly sales**: an interactive chart, a table and some SQL
        - **Attach a photo** with the photo button: the answer shows it back through the image loader
        """),
        .suggestions(starterPrompts),
    ]
}

@MainActor
@Observable
final class Conversation {
    var messages: [Message] = []
    /// A short confirmation, such as "Copied".
    var toast: String?
    @ObservationIgnored private var responseTask: Task<Void, Never>?
    var isResponding = false

    /// A conversation with one finished exchange, so the first screen has
    /// something to show.
    static func sample() -> Conversation {
        let conversation = Conversation()
        let question = Message(role: .user, text: "Plan a weekend in Lisbon for two")
        let answer = Message(role: .assistant)
        answer.prompt = question.text
        for step in Script.lisbon {
            switch step {
            case .text(let markdown): answer.parts.append(Part(content: .text(TextSegment(markdown: markdown))))
            case .part(let content): answer.parts.append(Part(content: content))
            case .layout(let make): answer.parts.append(Part(content: make()))
            case .callout(let symbol, let markdown):
                answer.parts.append(Part(content: .callout(symbol: symbol, text: TextSegment(markdown: markdown))))
            case .suggestions(let suggestions): answer.suggestions = suggestions
            case .status, .pause: break
            }
        }
        conversation.messages = [question, answer]
        return conversation
    }

    func send(_ text: String, attachments: [Attachment] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty, !isResponding else { return }
        for message in messages { message.suggestions = [] }
        messages.append(Message(role: .user, text: trimmed, attachments: attachments))
        let answer = Message(role: .assistant)
        answer.prompt = trimmed
        messages.append(answer)
        respond(into: answer, attachments: attachments)
    }

    /// Plays the answer again from the start.
    func regenerate(_ message: Message) {
        guard !isResponding, message.role == .assistant else { return }
        let index = messages.firstIndex { $0 === message } ?? 0
        let attachments = index > 0 ? messages[index - 1].attachments : []
        message.parts = []
        message.suggestions = []
        message.rating = nil
        message.wasStopped = false
        respond(into: message, attachments: attachments)
    }

    func stop() {
        responseTask?.cancel()
    }

    func startOver() {
        stop()
        messages = []
    }

    func showToast(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if toast == text { toast = nil }
        }
    }

    private func respond(into message: Message, attachments: [Attachment]) {
        isResponding = true
        message.isStreaming = true
        let steps = Script.steps(for: message.prompt, attachments: attachments)
        responseTask = Task {
            await play(steps, into: message)
            message.finishText()
            removeStatus(from: message)
            message.wasStopped = Task.isCancelled
            message.isStreaming = false
            isResponding = false
            responseTask = nil
        }
    }

    private func play(_ steps: [Script.Step], into message: Message) async {
        for step in steps {
            if Task.isCancelled { return }
            switch step {
            case .status(let text):
                message.streamingSegment?.finish()
                message.parts.append(Part(content: .status(text)))
            case .pause(let duration):
                try? await Task.sleep(for: duration)
            case .part(let content):
                message.streamingSegment?.finish()
                removeStatus(from: message)
                message.parts.append(Part(content: content))
                try? await Task.sleep(for: .milliseconds(250))
            case .layout(let make):
                message.streamingSegment?.finish()
                removeStatus(from: message)
                message.parts.append(Part(content: make()))
                try? await Task.sleep(for: .milliseconds(250))
            case .callout(let symbol, let markdown):
                message.streamingSegment?.finish()
                removeStatus(from: message)
                let segment = TextSegment()
                message.parts.append(Part(content: .callout(symbol: symbol, text: segment)))
                await stream(markdown, into: segment)
                segment.finish()
            case .text(let markdown):
                removeStatus(from: message)
                let segment: TextSegment
                if let current = message.streamingSegment {
                    segment = current
                    segment.append("\n\n")
                } else {
                    segment = TextSegment()
                    message.parts.append(Part(content: .text(segment)))
                }
                await stream(markdown, into: segment)
            case .suggestions(let suggestions):
                message.suggestions = suggestions
            }
        }
    }

    private func removeStatus(from message: Message) {
        message.parts.removeAll { if case .status = $0.content { return true } else { return false } }
    }

    /// Milliseconds between chunks; `-slow 1` makes it four times slower.
    private static let chunkPause = UserDefaults.standard.bool(forKey: "slow") ? 112 : 28

    /// A few characters at a time, at about the pace a fast model writes.
    private func stream(_ markdown: String, into segment: TextSegment) async {
        var rest = Substring(markdown)
        while !rest.isEmpty {
            if Task.isCancelled { return }
            let size = Int.random(in: 3...9)
            segment.append(String(rest.prefix(size)))
            rest = rest.dropFirst(size)
            try? await Task.sleep(for: .milliseconds(Self.chunkPause))
        }
    }
}
