#if canImport(UIKit) && !os(watchOS)
import Foundation
import Testing
import UIKit
@testable import TranscriptKit

// Assistive technologies can call accessibility getters and `UITextInput`
// methods from a background thread, through the Objective-C runtime. In
// the Swift 6 language mode, a main actor method called that way stops the
// process. These tests make such calls; the main actor stays free meanwhile.

private struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
}

/// Runs `body` on a background thread and returns its result.
@MainActor
private func offMain<Result>(_ body: @escaping @Sendable () -> Result) async -> Result {
    let result = await withCheckedContinuation { (continuation: CheckedContinuation<Unchecked<Result>, Never>) in
        Thread { continuation.resume(returning: Unchecked(value: body())) }.start()
    }
    return result.value
}

@MainActor
private func object(_ target: NSObject, _ name: String, _ argument: Any? = nil) async -> AnyObject? {
    let target = Unchecked(value: target)
    let argument = Unchecked(value: argument)
    return await offMain {
        target.value.perform(NSSelectorFromString(name), with: argument.value)?.takeUnretainedValue()
    }
}

/// Calls a method that takes one object and returns nothing.
@MainActor
private func call(_ target: NSObject, _ name: String, _ argument: Any?) async {
    let call = Unchecked(value: (target, argument))
    await offMain {
        typealias Method = @convention(c) (NSObject, Selector, Any?) -> Void
        let selector = NSSelectorFromString(name)
        let (target, argument) = call.value
        unsafeBitCast(target.method(for: selector), to: Method.self)(target, selector, argument)
    }
}

@MainActor
private func integer(_ target: NSObject, _ name: String) async -> Int {
    let target = Unchecked(value: target)
    return await offMain {
        typealias Getter = @convention(c) (NSObject, Selector) -> Int
        let selector = NSSelectorFromString(name)
        return unsafeBitCast(target.value.method(for: selector), to: Getter.self)(target.value, selector)
    }
}

@MainActor
private func bool(_ target: NSObject, _ name: String) async -> Bool {
    let target = Unchecked(value: target)
    return await offMain {
        typealias Getter = @convention(c) (NSObject, Selector) -> Bool
        let selector = NSSelectorFromString(name)
        return unsafeBitCast(target.value.method(for: selector), to: Getter.self)(target.value, selector)
    }
}

@MainActor
private func rect(_ target: NSObject, _ name: String, _ argument: NSObject? = nil) async -> CGRect {
    let target = Unchecked(value: target)
    let argument = Unchecked(value: argument)
    return await offMain {
        let selector = NSSelectorFromString(name)
        if let argument = argument.value {
            typealias Method = @convention(c) (NSObject, Selector, NSObject) -> CGRect
            return unsafeBitCast(target.value.method(for: selector), to: Method.self)(target.value, selector, argument)
        }
        typealias Getter = @convention(c) (NSObject, Selector) -> CGRect
        return unsafeBitCast(target.value.method(for: selector), to: Getter.self)(target.value, selector)
    }
}

@MainActor
private func viewWithText() -> TranscriptTextView {
    let view = TranscriptTextView(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
    view.document = MarkdownStreamParser.document(from: """
        # Title

        Some text with a [link](https://example.com).

        - One
        - Two

        | A | B |
        | - | - |
        | 1 | 2 |
        """)
    view.layoutIfNeeded()
    return view
}

@MainActor
@Test func accessibilityGettersWorkOffTheMainThread() async throws {
    let view = viewWithText()
    #expect(await !bool(view, "isAccessibilityElement"))
    let elements = try #require(await object(view, "accessibilityElements") as? [NSObject])
    #expect(elements.count == 5)
    #expect(await object(elements[0], "accessibilityLabel") as? String == "Title")
    #expect(await integer(elements[0], "accessibilityTraits") & Int(UIAccessibilityTraits.header.rawValue) != 0)
    #expect(await object(elements[3], "accessibilityValue") as? String == "Item 2 of 2")
    let actions = await object(elements[1], "accessibilityCustomActions") as? [UIAccessibilityCustomAction]
    #expect(actions?.count == 1)
    _ = await rect(elements[0], "accessibilityFrame")

    let table = elements[4]
    #expect(await !bool(table, "isAccessibilityElement"))
    #expect(await integer(table, "accessibilityContainerType") == UIAccessibilityContainerType.dataTable.rawValue)
    #expect(await integer(table, "accessibilityRowCount") == 2)
    #expect(await integer(table, "accessibilityColumnCount") == 2)
    let cells = try #require(await object(table, "accessibilityElements") as? [NSObject])
    #expect(cells.count == 4)
    #expect(await object(cells[3], "accessibilityLabel") as? String == "2")
    _ = await rect(cells[3], "accessibilityFrame")
    let header = await object(table, "accessibilityHeaderElementsForColumn:", NSNumber(value: 1))
    _ = header
    let rowRange = await offMain { [cell = Unchecked(value: cells[3])] in
        typealias Getter = @convention(c) (NSObject, Selector) -> NSRange
        let selector = NSSelectorFromString("accessibilityRowRange")
        return unsafeBitCast(cell.value.method(for: selector), to: Getter.self)(cell.value, selector)
    }
    #expect(rowRange == NSRange(location: 1, length: 1))
}

@MainActor
@Test func textInputWorksOffTheMainThread() async throws {
    let view = viewWithText()
    let start = try #require(await object(view, "beginningOfDocument") as? UITextPosition)
    let end = try #require(await object(view, "endOfDocument") as? TranscriptTextPosition)
    #expect(end.offset > 0)
    let all = view.textRange(from: start, to: end)!
    #expect((await object(view, "textInRange:", all) as? String)?.hasPrefix("Title") == true)
    #expect(await rect(view, "caretRectForPosition:", start).height > 0)
    #expect(await rect(view, "firstRectForRange:", all).height > 0)
    let rects = try #require(await object(view, "selectionRectsForRange:", all) as? [UITextSelectionRect])
    #expect(!rects.isEmpty)
    #expect(await rect(rects[0], "rect").height > 0)
    #expect((await object(all, "start") as? TranscriptTextPosition)?.offset == 0)
    #expect(await bool(view, "hasText"))
    #expect(await object(view, "selectedTextRange") == nil)
    _ = await object(view, "setSelectedTextRange:", all)
    #expect(view.selectedRange == (all as? TranscriptTextRange)?.range)
    let tokenizer = try #require(await object(view, "tokenizer") as? UITextInputTokenizer)
    let word = await offMain { [tokenizer = Unchecked(value: tokenizer), start = Unchecked(value: start)] in
        tokenizer.value.rangeEnclosingPosition(start.value, with: .word, inDirection: .storage(.forward))
    }
    #expect((word as? TranscriptTextRange)?.range == 0..<5)
}
@MainActor
@Test func settersActionsAndHitTestsWorkOffTheMainThread() async throws {
    let view = viewWithText()
    var opened: [URL] = []
    view.openLink = { opened.append($0) }
    let elements = try #require(await object(view, "accessibilityElements") as? [NSObject])
    let action = try #require((await object(elements[1], "accessibilityCustomActions") as? [UIAccessibilityCustomAction])?.first)
    let handled = await offMain { [action = Unchecked(value: action)] in action.value.actionHandler?(action.value) ?? false }
    #expect(handled)
    #expect(opened.map(\.absoluteString) == ["https://example.com"])

    let delegate = Delegate()
    await call(view, "setInputDelegate:", delegate)
    #expect(await object(view, "inputDelegate") === delegate)
    await call(view, "setInputDelegate:", nil)
    if #available(iOS 18.0, macCatalyst 18.0, *) {
        _ = await offMain { [view = Unchecked(value: view)] in view.value.writingToolsBehavior = .none }
        let behavior = await offMain { [view = Unchecked(value: view)] in view.value.writingToolsBehavior }
        #expect(behavior == .none)
        #expect(!view.showsWritingTools)
    }

    #expect(await bool(view, "canBecomeFirstResponder"))
    #expect(await object(view, "inputView") != nil)
    let inside = await offMain { [view = Unchecked(value: view)] in view.value.point(inside: CGPoint(x: 10, y: 10), with: nil) }
    #expect(inside)
    await call(view, "selectAll:", nil)
    #expect(view.selectedRange?.lowerBound == 0)
    let copy = await offMain { [view = Unchecked(value: view)] in
        view.value.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil)
    }
    #expect(copy)
}

private final class Delegate: NSObject, UITextInputDelegate {
    func selectionWillChange(_ textInput: (any UITextInput)?) {}
    func selectionDidChange(_ textInput: (any UITextInput)?) {}
    func textWillChange(_ textInput: (any UITextInput)?) {}
    func textDidChange(_ textInput: (any UITextInput)?) {}
}
#endif
