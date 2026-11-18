import Foundation
import os

/// A list that grows only at the end and whose versions share one buffer.
///
/// Copies behave like `Array` copies: each version keeps exactly the
/// elements it had. Unlike `Array`, appending to the newest version writes
/// into the shared buffer instead of copying it, so a list that grows by one
/// element while older versions are still in use costs O(1) per append, not
/// O(count). This is what lets every version of a streaming document, and of
/// its layout, share the blocks that have stopped changing.
///
/// The buffer is only ever written past the end of every existing version,
/// so a version can be read on one thread while a newer one is appended to
/// on another. Appending to an older version (one that something else has
/// already appended to) copies its elements into a new buffer, as `Array`
/// would.
struct SharedList<Element>: RandomAccessCollection {
    private var buffer: Buffer?
    private(set) var count = 0

    init() {}

    init(_ elements: [Element]) {
        guard !elements.isEmpty else { return }
        let buffer = Buffer(capacity: elements.count, lineage: Lineage(length: elements.count))
        elements.withUnsafeBufferPointer { buffer.elements.initialize(from: $0.baseAddress!, count: elements.count) }
        buffer.initialized = elements.count
        self.buffer = buffer
        count = elements.count
    }

    var startIndex: Int { 0 }
    var endIndex: Int { count }

    subscript(index: Int) -> Element {
        precondition(index >= 0 && index < count, "SharedList index out of range")
        return buffer.unsafelyUnwrapped.elements[index]
    }

    /// The first `length` elements, sharing this list's storage.
    func prefix(_ length: Int) -> SharedList {
        precondition(length >= 0)
        var result = self
        result.count = Swift.min(length, count)
        return result
    }

    mutating func removeLast() -> Element {
        let element = self[count - 1]
        // The element stays in the buffer for the versions that still have it.
        count -= 1
        return element
    }

    mutating func append(_ element: Element) {
        guard let buffer else {
            let fresh = Buffer(capacity: 4, lineage: Lineage(length: 1))
            fresh.elements.initialize(to: element)
            fresh.initialized = 1
            self.buffer = fresh
            count = 1
            return
        }

        // Nothing has been appended after this version if it is as long as
        // its lineage: the slot at `count` is then unused by anyone and its
        // buffer is the newest one. Checking and claiming happen under one lock.
        let replacement: Buffer? = buffer.lineage.state.withLockUnchecked { length in
            guard length == count else { return nil }
            if count < buffer.capacity {
                (buffer.elements + count).initialize(to: element)
                buffer.initialized = count + 1
                length = count + 1
                return buffer
            }
            // Full: continue in a bigger buffer. Older versions keep the old one.
            let bigger = Buffer(capacity: buffer.capacity * 2, lineage: buffer.lineage)
            bigger.elements.initialize(from: buffer.elements, count: count)
            (bigger.elements + count).initialize(to: element)
            bigger.initialized = count + 1
            length = count + 1
            return bigger
        }
        if let replacement {
            self.buffer = replacement
            count += 1
            return
        }

        // Another version has already grown past this one: start a new
        // lineage, with some room to grow.
        let fork = Buffer(capacity: Swift.max(4, (count + 1) * 3 / 2), lineage: Lineage(length: count + 1))
        fork.elements.initialize(from: buffer.elements, count: count)
        (fork.elements + count).initialize(to: element)
        fork.initialized = count + 1
        self.buffer = fork
        count += 1
    }

    mutating func append<S: Sequence>(contentsOf elements: S) where S.Element == Element {
        for element in elements { append(element) }
    }

    /// Whether `other` is known to be the first `other.count` elements of
    /// this list without comparing them: both are versions of the same
    /// sequence of appends. A false result says nothing either way.
    func extendsStorage(of other: SharedList) -> Bool {
        if other.count == 0 { return true }
        guard other.count <= count, let mine = buffer?.lineage, let theirs = other.buffer?.lineage else { return false }
        return mine === theirs
    }

    // MARK: Storage

    /// One sequence of appends. Versions that share a lineage are prefixes
    /// of one another; `length` is the longest of them.
    private final class Lineage: Sendable {
        let state: OSAllocatedUnfairLock<Int>

        init(length: Int) {
            state = OSAllocatedUnfairLock(initialState: length)
        }
    }

    private final class Buffer: @unchecked Sendable {
        let lineage: Lineage
        let capacity: Int
        let elements: UnsafeMutablePointer<Element>
        /// Written under `lineage.state`'s lock, or before the buffer is shared.
        var initialized = 0

        init(capacity: Int, lineage: Lineage) {
            self.capacity = capacity
            self.lineage = lineage
            elements = .allocate(capacity: capacity)
        }

        deinit {
            elements.deinitialize(count: initialized)
            elements.deallocate()
        }
    }
}

extension SharedList: @unchecked Sendable where Element: Sendable {}

extension SharedList: Equatable where Element: Equatable {
    static func == (lhs: SharedList, rhs: SharedList) -> Bool {
        guard lhs.count == rhs.count else { return false }
        if lhs.extendsStorage(of: rhs) { return true }
        return lhs.elementsEqual(rhs)
    }
}
