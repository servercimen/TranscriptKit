#if canImport(UIKit) && !os(watchOS)
import Foundation

/// Runs `body` on the main thread and returns its result: at once on the
/// main thread, and otherwise after the main thread has run it.
///
/// Assistive technologies, such as VoiceOver, Speak Screen, Voice Control
/// and the text rotor, can call accessibility getters and `UITextInput`
/// methods from other threads. In the Swift 6 language mode, a main actor
/// method that Objective-C calls from another thread stops the app, so
/// those methods are `nonisolated` and do their work here. Only the calling
/// thread waits: the main thread never waits for another thread here.
nonisolated func onMainThread<Result>(_ body: @MainActor () -> Result) -> Result {
    if Thread.isMainThread {
        return MainActor.assumeIsolated { MainThreadResult(value: body()) }.value
    }
    return DispatchQueue.main.sync { MainActor.assumeIsolated { MainThreadResult(value: body()) } }.value
}

/// A result that goes from the main thread to the thread that waits for it.
/// The main thread hands it over and does not keep it.
private struct MainThreadResult<Value>: @unchecked Sendable {
    let value: Value
}
#endif
