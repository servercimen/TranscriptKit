import Foundation
import Testing
@testable import TranscriptKit

@Test func versionsKeepTheirOwnElements() {
    var a = SharedList<Int>()
    for i in 0..<10 { a.append(i) }
    let snapshot = a
    for i in 10..<100 { a.append(i) }
    #expect(Array(snapshot) == Array(0..<10))
    #expect(Array(a) == Array(0..<100))
    #expect(a.extendsStorage(of: snapshot))
    #expect(!snapshot.extendsStorage(of: a))
}

@Test func appendingToAnOlderVersionForks() {
    var a = SharedList<String>()
    a.append("x")
    a.append("y")
    var older = a
    a.append("a")
    older.append("b")
    #expect(Array(a) == ["x", "y", "a"])
    #expect(Array(older) == ["x", "y", "b"])
    // Not known to share storage any more, but still equal by value up to "y".
    #expect(!a.extendsStorage(of: older))
    #expect(a.prefix(2) == older.prefix(2))
    #expect(a != older)
}

@Test func prefixAndRemoveLastShareStorage() {
    var a = SharedList((0..<40).map { "\($0)" })
    let first = a.prefix(20)
    #expect(a.extendsStorage(of: first))
    #expect(first.count == 20 && first.last == "19")
    #expect(a.removeLast() == "39")
    #expect(a.count == 39)
    // The removed slot is still in use by `first`'s lineage, so this forks.
    a.append("new")
    #expect(a.last == "new" && a[38] == "38")
    #expect(first.count == 20)
}

/// Elements are released when the last version holding them goes away.
@Test func elementsAreReleased() {
    final class Probe {}
    weak var weakProbe: Probe?
    do {
        var list = SharedList<Probe>()
        let probe = Probe()
        weakProbe = probe
        list.append(probe)
        for _ in 0..<40 { list.append(Probe()) }
        #expect(weakProbe != nil)
    }
    #expect(weakProbe == nil)
}

/// One thread appends while others read older versions.
@Test func concurrentReadersSeeStableVersions() async {
    var list = SharedList<Int>()
    var versions: [SharedList<Int>] = []
    for i in 0..<2000 {
        list.append(i)
        if i % 100 == 0 { versions.append(list) }
    }
    let shared = versions
    let final = list
    await withTaskGroup(of: Bool.self) { group in
        for version in shared {
            group.addTask {
                version.enumerated().allSatisfy { $0.offset == $0.element }
            }
        }
        group.addTask {
            var copy = final
            for i in 2000..<10_000 { copy.append(i) }
            return copy.count == 10_000 && copy[9_999] == 9_999
        }
        for await ok in group { #expect(ok) }
    }
}
