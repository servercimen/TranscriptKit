#if canImport(UIKit) && !os(watchOS)
import Foundation
import Testing
import UIKit
@testable import TranscriptKit

/// Lets the main actor run until `condition` holds, for at most two seconds.
@MainActor
private func wait(until condition: () -> Bool) async {
    let deadline = Date(timeIntervalSinceNow: 2)
    while !condition(), Date() < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
private func elements(of view: TranscriptTextView) -> [UIAccessibilityElement] {
    (view.accessibilityElements as? [UIAccessibilityElement]) ?? []
}

@MainActor
@Test func elementsStayTheSameObjectsWhileTextStreams() async {
    let view = TranscriptTextView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
    let parser = { (markdown: String) in MarkdownStreamParser.document(from: markdown, idPrefix: "t") }
    view.document = parser("# Title\n\nFirst words")
    view.layoutIfNeeded()
    let before = elements(of: view)
    #expect(before.map(\.accessibilityLabel) == ["Title", "First words"])

    view.document = parser("# Title\n\nFirst words and more")
    await wait { elements(of: view).last?.accessibilityLabel == "First words and more" }
    let longer = elements(of: view)
    #expect(longer.count == 2)
    #expect(zip(before, longer).allSatisfy { $0 === $1 })

    view.document = parser("# Title\n\nFirst words and more\n\nNew block")
    await wait { elements(of: view).count == 3 }
    let added = elements(of: view)
    #expect(added.count == 3)
    #expect(added[0] === before[0] && added[1] === before[1])

    view.frame.size.width = 200
    view.layoutIfNeeded()
    let narrower = elements(of: view)
    #expect(zip(added, narrower).allSatisfy { $0 === $1 })
    #expect(narrower[1].accessibilityFrameInContainerSpace.width == 200)
}
#endif
