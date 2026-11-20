import Foundation

/// Turns one block's inline Markdown into display text plus style spans.
///
/// Supported: `*`/`_` emphasis, `**`/`__` strong, `~~` strikethrough, code
/// spans, `[text](url)` and reference links, `![alt](url)` images, `<scheme:...>` and bare
/// `https://`/`www.` autolinks, backslash escapes, numeric and HTML's named
/// entities, and a few HTML tags: `<br>`, `<b>`, `<strong>`, `<i>`, `<em>`,
/// `<u>`, `<s>`, `<del>`, `<code>`, `<kbd>`, and the app's custom tags (see
/// `TranscriptTag`), which may have attributes. HTML comments are hidden;
/// other tags show as written.
///
/// In `open` mode the text is the still-growing tail of a stream. Markup that
/// has not been closed yet is treated as if it closed at the end, and a
/// trailing run of markup characters is held back until the next characters
/// show what it is. Together these keep the displayed text growing at its end
/// only, so nothing already on screen is restyled or shifted when the closer
/// arrives.
///
/// The parser works on UTF-16 code units (all markup is ASCII) and can resume
/// from a `Checkpoint`, so a block that grows by a few characters is parsed
/// from where the last certain decision was made, not from its start.
enum InlineParser {
    struct Result: Equatable {
        var text: String
        var spans: [InlineSpan]
    }

    /// The parser's state after part of the source, from which a later parse
    /// of a longer version of the same source can resume.
    ///
    /// Only decisions that no later text can change are recorded in it: a
    /// token is taken into the checkpoint only if every unit it looked at is
    /// in the stable part of the source, and it did not depend on where the
    /// text currently ends (an unclosed code span, a link still missing its
    /// `)`, a delimiter run at the very end, ...).
    struct Checkpoint: Sendable {
        /// Source units consumed so far.
        fileprivate(set) var position = 0
        fileprivate var output: [UInt16] = []
        fileprivate var pieces: [Piece] = []
        fileprivate var lastPieceIsOpenText = false
        fileprivate var spans: [PendingSpan] = []
        fileprivate var delimiters: [Delimiter] = []
        fileprivate var brackets: [Bracket] = []
        /// Open HTML tags, innermost last.
        fileprivate var tags: [Tag] = []

        /// The result for the pieces that can no longer change, so that a
        /// parse makes only the text and spans after them (see `settle()`).
        /// Pieces below `settledPieces` never change, in this checkpoint or
        /// in any state made from it: only pieces an open delimiter, bracket
        /// or tag refers to, and the open text piece at the end, still can.
        fileprivate var settledPieces = 0
        fileprivate var settledText = ""
        /// UTF-16 offset of the start of each settled piece, and of their end.
        fileprivate var settledOffsets: [Int] = [0]
        /// Resolved spans that lie entirely in the settled pieces, sorted,
        /// with their index in `spans`; they are the first `settledSpanCount` of it.
        fileprivate var settledSpans: [(span: InlineSpan, index: Int)] = []
        /// The same spans without their indexes, ready to hand out.
        fileprivate var settledSpanList: [InlineSpan] = []
        fileprivate var settledSpanCount = 0

        init() {}
    }

    fileprivate struct Bracket {
        /// A sealed piece holding "[" (a link) or "![" (an image).
        let piece: Int
        let isImage: Bool
        /// Where the bracket's text starts in the source, for reference labels.
        let sourceStart: Int
    }

    /// While streaming, an open "[" hides what follows it for this many
    /// units: long enough for a link's text, so that neither a link nor a
    /// literal "[1]" changes text already shown. A longer one shows as written.
    private static let openBracketReach = 64

    /// While streaming, an open formula hides what follows it for this many
    /// units, so that the text only grows. A longer one shows as plain text,
    /// as it does if it never closes.
    private static let openMathReach = 512

    fileprivate struct Tag {
        let name: String
        let traits: InlineSpan.Traits
        /// An empty sealed piece where the tag was.
        let piece: Int
        /// For a custom tag: what it is, with its decoration worked out.
        var custom: InlineSpan.CustomTag? = nil
    }

    /// Longer tags, from "<" to ">", show as written; while streaming, a
    /// tag still arriving is hidden for at most this many units.
    static let maximumTagLength = 256

    /// Output is built from pieces so that a delimiter can later be removed
    /// (when it turns out to be markup) without disturbing span positions.
    /// A piece is a range of `output`; pieces only ever shrink.
    fileprivate struct Piece {
        var start: Int
        var length: Int
    }

    fileprivate struct Delimiter {
        let character: UInt16
        var count: Int
        let piece: Int
    }

    fileprivate struct PendingSpan {
        let from: Int
        let to: Int
        let traits: InlineSpan.Traits
        let link: String?
        /// Made once, and shared by every span made from this one.
        let extras: InlineSpan.Extras?

        init(from: Int, to: Int, traits: InlineSpan.Traits, link: String?, image: TranscriptImage? = nil,
             reference: String? = nil, customTag: InlineSpan.CustomTag? = nil, math: TranscriptMath? = nil) {
            self.from = from
            self.to = to
            self.traits = traits
            self.link = link
            self.extras = InlineSpan.Extras.make(image: image, reference: reference, customTag: customTag, math: math)
        }

        func span(_ range: Range<Int>) -> InlineSpan {
            InlineSpan(range: range, traits: traits, link: link, extras: extras)
        }
    }

    /// Whether every parse also rebuilds its whole result and checks that the
    /// settled part matches. On only under a test runner: in an app's debug
    /// build it would double the cost of every parse. Swift Testing can run
    /// without loading XCTest, so a loaded `.xctest` bundle also counts.
    static let checksSettledResult: Bool = {
        if NSClassFromString("XCTestCase") != nil { return true }
        if Bundle.allBundles.contains(where: { $0.bundlePath.hasSuffix(".xctest") }) { return true }
        return ProcessInfo.processInfo.arguments.contains { $0.hasSuffix(".xctest") || $0.contains(".xctest/") }
    }()

    /// Parses a whole string.
    static func parse(_ source: String, open: Bool, tags: [String: TranscriptTag] = [:]) -> Result {
        var checkpoint = Checkpoint()
        return parse(BlockParser.utf16(source), open: open, stableLength: 0, resumingFrom: &checkpoint, tags: tags)
    }

    /// Parses `units`, resuming from `checkpoint` and advancing it.
    ///
    /// - Parameters:
    ///   - stableLength: the units before this index are the same in every
    ///     later call made with this checkpoint. Pass 0 to keep nothing.
    ///   - checkpoint: state from an earlier call on a prefix of the same
    ///     source, or a fresh one.
    ///   - tags: the app's custom tags, by name. The same in every call
    ///     made with this checkpoint.
    static func parse(_ units: [UInt16], open: Bool, stableLength: Int, resumingFrom checkpoint: inout Checkpoint,
                      tags: [String: TranscriptTag] = [:]) -> Result {
        let count = open ? visibleCount(of: units) : units.count
        if checkpoint.position > count {
            // Cannot happen if the caller keeps its promise; start over rather than misparse.
            assertionFailure("Inline checkpoint is past the end of the source")
            checkpoint = Checkpoint()
        }
        let limit = min(stableLength, count)
        // Bare email addresses are only looked for in text that has an "@".
        let emails = units[checkpoint.position..<count].contains(atSign)
        // Decisions that are final go into the checkpoint...
        while checkpoint.position < limit,
              step(&checkpoint, units, count: count, open: open, limit: limit, emails: emails, tags: tags) {}
        checkpoint.settle()
        // ...and the rest is parsed on a copy, every time.
        var state = checkpoint
        while state.position < count {
            _ = step(&state, units, count: count, open: open, limit: nil, emails: emails, tags: tags)
        }
        if open { closeAtEnd(&state, count: count) }
        // An HTML tag left open styles the rest of the block, as in a browser.
        // While the block is still being written, its closing tag may yet
        // come, which an animated custom tag waits for.
        for tag in state.tags {
            state.spans.append(PendingSpan(from: tag.piece + 1, to: state.pieces.count, traits: tag.traits,
                                           link: tag.custom?.decoration.link, customTag: open ? tag.custom?.waitingToClose : tag.custom))
        }
        return state.result()
    }

    // MARK: Units

    private static let backslash = UInt16(UInt8(ascii: "\\"))
    private static let backtick = UInt16(UInt8(ascii: "`"))
    private static let star = UInt16(UInt8(ascii: "*"))
    private static let underscore = UInt16(UInt8(ascii: "_"))
    private static let bang = UInt16(UInt8(ascii: "!"))
    private static let openBracket = UInt16(UInt8(ascii: "["))
    private static let closeBracket = UInt16(UInt8(ascii: "]"))
    private static let openParen = UInt16(UInt8(ascii: "("))
    private static let closeParen = UInt16(UInt8(ascii: ")"))
    private static let lessThan = UInt16(UInt8(ascii: "<"))
    private static let greaterThan = UInt16(UInt8(ascii: ">"))
    private static let ampersand = UInt16(UInt8(ascii: "&"))
    private static let colon = UInt16(UInt8(ascii: ":"))
    private static let space = UInt16(UInt8(ascii: " "))
    private static let tilde = UInt16(UInt8(ascii: "~"))
    private static let slash = UInt16(UInt8(ascii: "/"))
    private static let hash = UInt16(UInt8(ascii: "#"))
    private static let semicolon = UInt16(UInt8(ascii: ";"))
    private static let dash = UInt16(UInt8(ascii: "-"))
    private static let newline = UInt16(UInt8(ascii: "\n"))
    private static let objectReplacement: UInt16 = 0xFFFC
    private static let atSign = UInt16(UInt8(ascii: "@"))
    private static let dot = UInt16(UInt8(ascii: "."))
    private static let dollar = UInt16(UInt8(ascii: "$"))

    private static func isSpecial(_ unit: UInt16) -> Bool {
        switch unit {
        case backslash, backtick, star, underscore, tilde, bang, openBracket, closeBracket, lessThan, ampersand, dollar: return true
        default: return false
        }
    }

    private static let escapable = Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~".utf16)
    /// Trailing units that are held back in open mode: each could be the
    /// start of markup that the next characters decide.
    private static let heldBackWhenTrailing = Set("*_~`\\[]!$".utf16)

    private static var longestEntityName: Int { HTMLEntities.longestName }

    private static func isASCIIDigit(_ unit: UInt16) -> Bool { (0x30...0x39).contains(unit) }

    private static func isHexDigit(_ unit: UInt16) -> Bool {
        isASCIIDigit(unit) || (0x41...0x46).contains(unit) || (0x61...0x66).contains(unit)
    }

    private enum EntityScan {
        /// The reference is `length` units long and stands for `value`.
        case match(length: Int, value: [UInt16])
        case noMatch
        /// The text ends while the reference could still be completed.
        case incomplete
    }

    /// Reads a character reference at `i` ("&amp;", "&#233;", "&#x1F600;").
    private static func scanEntity(at i: Int, in units: [UInt16], count: Int) -> EntityScan {
        var k = i + 1
        guard k < count else { return .incomplete }
        if units[k] == hash {
            k += 1
            guard k < count else { return .incomplete }
            let isHex = units[k] == 0x78 || units[k] == 0x58 // x X
            if isHex { k += 1 }
            let digitsStart = k
            let maximum = isHex ? 6 : 7
            while k < count, k - digitsStart < maximum, isHex ? isHexDigit(units[k]) : isASCIIDigit(units[k]) { k += 1 }
            guard k < count else { return .incomplete }
            guard k > digitsStart, units[k] == semicolon else { return .noMatch }
            let digits = String(decoding: units[digitsStart..<k], as: UTF16.self)
            let code = UInt32(digits, radix: isHex ? 16 : 10) ?? 0
            let scalar = code == 0 ? nil : Unicode.Scalar(code)
            return .match(length: k + 1 - i, value: Array(String(scalar ?? "\u{FFFD}").utf16))
        }
        let nameStart = k
        while k < count, k - nameStart < longestEntityName, isASCIILetter(units[k]) || isASCIIDigit(units[k]) { k += 1 }
        let name = String(decoding: units[nameStart..<k], as: UTF16.self)
        guard k < count else {
            // "&am" and "&amp" can both still become "&amp;".
            return name.isEmpty || HTMLEntities.hasName(startingWith: name) ? .incomplete : .noMatch
        }
        guard units[k] == semicolon, let value = HTMLEntities.values[name] else { return .noMatch }
        return .match(length: k + 1 - i, value: value)
    }

    /// The number of units shown in open mode: the source without trailing
    /// held-back markup or a trailing unfinished entity (shown literally now,
    /// it would collapse into one character once complete).
    private static func visibleCount(of units: [UInt16]) -> Int {
        var count = units.count
        while true {
            let before = count
            while count > 0, heldBackWhenTrailing.contains(units[count - 1]) { count -= 1 }
            let window = max(0, count - longestEntityName - 3)
            if let amp = (window..<count).last(where: { units[$0] == ampersand }),
               case .incomplete = scanEntity(at: amp, in: units, count: count) {
                count = amp
            }
            if count == before { return count }
        }
    }

    private static func runLength(of unit: UInt16, at index: Int, in units: [UInt16], count: Int) -> Int {
        var end = index
        while end < count, units[end] == unit { end += 1 }
        return end - index
    }

    // MARK: Character classes

    /// The first scalar of the character before `index`: combining marks and
    /// other extending scalars are skipped, so "e" + U+0301 counts as a
    /// letter, as `Character.isLetter` would say.
    private static func scalar(before index: Int, in units: [UInt16]) -> Unicode.Scalar? {
        var end = index
        while end > 0 {
            let last = units[end - 1]
            let scalar: Unicode.Scalar?
            let start: Int
            if UTF16.isTrailSurrogate(last), end >= 2, UTF16.isLeadSurrogate(units[end - 2]) {
                scalar = combine(units[end - 2], last)
                start = end - 2
            } else {
                scalar = Unicode.Scalar(last)
                start = end - 1
            }
            guard let scalar else { return nil }
            if start > 0, !scalar.isASCII, isExtending(scalar) {
                end = start
                continue
            }
            return scalar
        }
        return nil
    }

    private static func isExtending(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x200D, 0xFE00...0xFE0F, 0x1F3FB...0x1F3FF: return true
        default:
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark: return true
            default: return false
            }
        }
    }

    /// The scalar starting at `index` and the index just past it.
    private static func scalar(at index: Int, in units: [UInt16], count: Int) -> (scalar: Unicode.Scalar?, end: Int) {
        let first = units[index]
        if UTF16.isLeadSurrogate(first), index + 1 < count, UTF16.isTrailSurrogate(units[index + 1]) {
            return (combine(first, units[index + 1]), index + 2)
        }
        return (Unicode.Scalar(first), index + 1)
    }

    private static func combine(_ lead: UInt16, _ trail: UInt16) -> Unicode.Scalar? {
        Unicode.Scalar(0x10000 + ((UInt32(lead) - 0xD800) << 10) + (UInt32(trail) - 0xDC00))
    }

    private static func isWhitespace(_ scalar: Unicode.Scalar?) -> Bool {
        guard let scalar else { return false }
        if scalar.isASCII {
            return scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" || scalar.value == 0x0B || scalar.value == 0x0C
        }
        return scalar.properties.isWhitespace
    }

    /// A letter or digit. `_` inside a word (snake_case) is never emphasis.
    private static func isWordCharacter(_ scalar: Unicode.Scalar?) -> Bool {
        guard let scalar else { return false }
        if scalar.isASCII {
            let value = scalar.value
            return (0x30...0x39).contains(value) || (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value)
        }
        return scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }

    private static func isSchemeCharacter(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2B, 0x2D, 0x2E: return true // digits, letters, + - .
        default: return false
        }
    }

    private static func isASCIILetter(_ unit: UInt16) -> Bool {
        (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit)
    }

    // MARK: Tokens

    /// Parses one token at `state.position`. With a `limit`, a token that
    /// would need to look at a unit at or past it is left unparsed and the
    /// result is false.
    private static func step(_ state: inout Checkpoint, _ units: [UInt16], count: Int, open: Bool, limit: Int?, emails: Bool,
                             tags: [String: TranscriptTag]) -> Bool {
        let i = state.position
        /// Whether a token whose decision looked at units up to `peek`
        /// (inclusive; `count` meaning it depended on where the text ends) may be taken.
        func allowed(_ peek: Int) -> Bool {
            guard let limit else { return true }
            return peek < limit
        }
        let unit = units[i]

        switch unit {
        case backslash:
            // "\(" … "\)" is inline math. "\[" … "\]" is display math only
            // at the start of a line, where the block parser finds it; in a
            // line, "\[" is an escaped "[".
            if i + 1 < count, units[i + 1] == openParen {
                if let close = mathClose(from: i + 2, in: units, count: count, closer: closeParen) {
                    guard allowed(close + 1) else { return false }
                    takeMath(&state, units, opener: i, close: close, display: false)
                    state.position = close + 2
                    return true
                }
                // Whether it closes later depends on text that may still come.
                guard allowed(count) else { return false }
                if open, count - i <= openMathReach {
                    state.position = count
                    return true
                }
            }
            guard i + 1 < count else {
                guard allowed(count) else { return false }
                state.appendText(units[i..<(i + 1)])
                state.position = i + 1
                return true
            }
            guard allowed(i + 1) else { return false }
            if escapable.contains(units[i + 1]) {
                state.appendText(units[(i + 1)..<(i + 2)])
                state.position = i + 2
            } else {
                state.appendText(units[i..<(i + 1)])
                state.position = i + 1
            }

        case backtick:
            let run = runLength(of: backtick, at: i, in: units, count: count)
            let contentStart = i + run
            var close: Int?
            var peek = count
            var k = contentStart
            while k < count {
                if units[k] == backtick {
                    let length = runLength(of: backtick, at: k, in: units, count: count)
                    if length == run {
                        close = k
                        peek = k + length
                        break
                    }
                    k += length
                } else {
                    k += 1
                }
            }
            guard allowed(peek) else { return false }
            if close != nil || open {
                let contentEnd = close ?? count
                var content = units[contentStart..<contentEnd]
                if close != nil, content.count >= 2, content.first == space, content.last == space,
                   content.contains(where: { $0 != space }) {
                    content = content.dropFirst().dropLast()
                }
                if !content.isEmpty {
                    let piece = state.appendSealedPiece(content)
                    state.addSpan(from: piece, traits: .code)
                }
                state.position = close.map { $0 + run } ?? count
            } else {
                state.appendText(units[i..<contentStart])
                state.position = contentStart
            }

        case star, underscore, tilde:
            let run = runLength(of: unit, at: i, in: units, count: count)
            let nextIndex = i + run
            if unit == tilde, run != 2 {
                // Only "~~" strikes through: a single "~" is "about" in "~5 min".
                guard allowed(nextIndex < count ? nextIndex : count) else { return false }
                state.appendText(repeating: unit, count: run)
                state.position = nextIndex
                return true
            }
            let next: Unicode.Scalar?
            let peek: Int
            if nextIndex < count {
                let decoded = scalar(at: nextIndex, in: units, count: count)
                next = decoded.scalar
                // Half a surrogate pair at the end: the character is not known yet.
                let isSplitPair = UTF16.isLeadSurrogate(units[nextIndex]) && decoded.end == nextIndex + 1
                peek = isSplitPair ? count : decoded.end - 1
            } else {
                next = nil
                peek = count
            }
            guard allowed(peek) else { return false }
            let previous = scalar(before: i, in: units)
            // "_" inside a word (snake_case) is never emphasis; "*" and "~~" can be.
            let isIntraword = unit != underscore
            let canOpen = nextIndex < count && !isWhitespace(next) && (isIntraword || !isWordCharacter(previous))
            let canClose = i > 0 && !isWhitespace(previous) && (isIntraword || !isWordCharacter(next))

            if run > 3 { state.appendText(repeating: unit, count: run - 3) }
            var remaining = min(run, 3)
            if canClose {
                while remaining > 0, let index = state.delimiters.lastIndex(where: { $0.character == unit }) {
                    let used = min(state.delimiters[index].count, remaining)
                    state.addSpan(from: state.delimiters[index].piece + 1, traits: traits(for: unit, count: used))
                    state.delimiters[index].count -= used
                    state.pieces[state.delimiters[index].piece].length = state.delimiters[index].count
                    remaining -= used
                    // Openers above the match were never closed; they stay literal.
                    let keep = state.delimiters[index].count > 0 ? index + 1 : index
                    state.delimiters.removeSubrange(keep...)
                }
            }
            if remaining > 0 {
                if canOpen {
                    let piece = state.appendSealedPiece(repeating: unit, count: remaining)
                    state.delimiters.append(Delimiter(character: unit, count: remaining, piece: piece))
                } else {
                    state.appendText(repeating: unit, count: remaining)
                }
            }
            state.position = nextIndex

        case bang:
            guard i + 1 < count else {
                guard allowed(count) else { return false }
                state.appendText(units[i..<(i + 1)])
                state.position = i + 1
                return true
            }
            guard allowed(i + 1) else { return false }
            if units[i + 1] == openBracket {
                // "![": an image, if a "](url)" follows.
                let piece = state.appendSealedPiece(units[i..<(i + 2)])
                state.brackets.append(Bracket(piece: piece, isImage: true, sourceStart: i + 2))
                state.position = i + 2
            } else {
                state.appendText(units[i..<(i + 1)])
                state.position = i + 1
            }

        case openBracket:
            guard allowed(i) else { return false }
            state.brackets.append(Bracket(piece: state.appendSealedPiece(units[i..<(i + 1)]), isImage: false, sourceStart: i + 1))
            state.position = i + 1

        case closeBracket:
            guard !state.brackets.isEmpty else {
                guard allowed(i) else { return false }
                state.appendText(units[i..<(i + 1)])
                state.position = i + 1
                return true
            }
            guard i + 1 < count, units[i + 1] == openParen else {
                let opener = state.brackets[state.brackets.count - 1]
                var peek = i + 1 < count ? i + 1 : count
                if i + 1 < count, units[i + 1] == openBracket, !opener.isImage {
                    // "[text][label]" or "[label][]": a reference link.
                    var k = i + 2
                    var close: Int?
                    while k < count {
                        if units[k] == backslash { k += 2; continue }
                        if units[k] == openBracket { break }
                        if units[k] == closeBracket { close = k; break }
                        k += 1
                    }
                    peek = min(k, count)
                    if let close {
                        guard allowed(close) else { return false }
                        let second = units[(i + 2)..<close]
                        let raw = second.isEmpty ? units[opener.sourceStart..<i] : second
                        let label = BlockParser.normalizedLabel(String(decoding: raw, as: UTF16.self))
                        if !label.isEmpty, raw.count <= 999 {
                            state.brackets.removeLast()
                            state.pieces[opener.piece].length = 0
                            state.addSpan(from: opener.piece + 1, reference: label)
                            state.position = close + 1
                            return true
                        }
                    } else if k >= count, open {
                        guard allowed(count) else { return false }
                        // The label is still arriving: the text shows, the label does not.
                        state.brackets.removeLast()
                        state.pieces[opener.piece].length = 0
                        state.position = count
                        return true
                    }
                }
                // Not a link: the bracket pair stays literal ("[1]" stays
                // "[1]"), and links as a shortcut reference if the document
                // defines its label.
                guard allowed(peek) else { return false }
                state.brackets.removeLast()
                state.appendText(units[i..<(i + 1)])
                let raw = units[opener.sourceStart..<i]
                if !opener.isImage, raw.count <= 999, !raw.contains(openBracket) {
                    let label = BlockParser.normalizedLabel(String(decoding: raw, as: UTF16.self))
                    if !label.isEmpty { state.addSpan(from: opener.piece, reference: label) }
                }
                state.position = i + 1
                return true
            }
            var depth = 0
            var close: Int?
            var k = i + 2
            while k < count {
                if units[k] == openParen { depth += 1 }
                if units[k] == closeParen {
                    if depth == 0 { close = k; break }
                    depth -= 1
                }
                k += 1
            }
            guard allowed(close ?? count) else { return false }
            let opener = state.brackets.removeLast()
            if close != nil || open {
                let raw = String(decoding: units[(i + 2)..<(close ?? count)], as: UTF16.self)
                    .trimmingCharacters(in: .whitespaces)
                var destination = String(raw.prefix { !$0.isWhitespace })
                if destination.hasPrefix("<"), destination.hasSuffix(">"), destination.count >= 2 {
                    destination = String(destination.dropFirst().dropLast())
                }
                if opener.isImage {
                    if close == nil {
                        // Still arriving: nothing of it is shown until it is whole.
                        state.hide(from: opener.piece)
                    } else {
                        // The alt text is kept as plain text; markup inside it goes.
                        let alt = state.plainText(from: opener.piece + 1)
                        state.hide(from: opener.piece)
                        state.delimiters.removeAll { $0.piece > opener.piece }
                        state.tags.removeAll { $0.piece > opener.piece }
                        let piece = state.appendSealedPiece(CollectionOfOne(objectReplacement))
                        state.addSpan(from: piece, image: TranscriptImage(source: destination, alt: alt))
                    }
                } else {
                    state.pieces[opener.piece].length = 0
                    state.addSpan(from: opener.piece + 1, link: destination)
                }
                state.position = close.map { $0 + 1 } ?? count
            } else {
                state.appendText(units[i..<(i + 1)])
                state.position = i + 1
            }

        case lessThan:
            // `<scheme:rest>` with a scheme of two or more characters and no
            // spaces, an HTML tag from the supported set, or a comment.
            // Decided at the first unit that rules them out, so a lone
            // "a < b" never keeps the rest of the block undecided.
            enum Outcome {
                case literal, autolink(end: Int), email(end: Int), pending(show: Bool)
                case tag(name: String, closing: Bool, end: Int), comment(end: Int)
                case customTag(TranscriptTag, attributes: [String: String], end: Int)
            }
            var outcome = Outcome.literal
            var peek = i + 1
            /// How far the check for "<local@domain>" looked.
            var emailPeek = 0
            var j = i + 1
            scan: do {
                guard j < count else { outcome = .pending(show: false); peek = count; break scan }
                if units[j] == bang {
                    // "<!--" ... "-->", hidden.
                    let opener: [UInt16] = [bang, dash, dash]
                    var k = 0
                    while k < 3, j + k < count, units[j + k] == opener[k] { k += 1 }
                    guard k == 3 else {
                        if j + k >= count { outcome = .pending(show: false); peek = count } else { peek = j + k }
                        break scan
                    }
                    var m = j + 3
                    while m + 2 < count, !(units[m] == dash && units[m + 1] == dash && units[m + 2] == greaterThan) { m += 1 }
                    guard m + 2 < count else { outcome = .pending(show: false); peek = count; break scan }
                    outcome = .comment(end: m + 3)
                    peek = m + 2
                    break scan
                }
                if units[j] == slash {
                    // A closing tag: "</name>".
                    var k = j + 1
                    // Custom tag names may have hyphens.
                    while k < count, isASCIILetter(units[k]) || isASCIIDigit(units[k]) || units[k] == dash { k += 1 }
                    let nameEnd = k
                    while k < count, units[k] == space { k += 1 }
                    guard k < count, k - i < maximumTagLength else {
                        if k >= count, count - i < maximumTagLength { outcome = .pending(show: false); peek = count } else { peek = k }
                        break scan
                    }
                    peek = k
                    let name = String(decoding: units[(j + 1)..<nameEnd], as: UTF16.self).lowercased()
                    if units[k] == greaterThan, htmlTags[name] != nil || tags[name] != nil {
                        outcome = .tag(name: name, closing: true, end: k + 1)
                    }
                    break scan
                }
                // "<local@domain>": an email address.
                var e = j
                while e < count, isBracketedEmailLocal(units[e]) { e += 1 }
                guard e < count else { outcome = .pending(show: false); peek = count; break scan }
                emailPeek = e
                if units[e] == atSign, e > j {
                    var m = e + 1
                    while m < count, isASCIILetter(units[m]) || isASCIIDigit(units[m]) || units[m] == dash || units[m] == dot { m += 1 }
                    guard m < count else { outcome = .pending(show: false); peek = count; break scan }
                    peek = m
                    if units[m] == greaterThan, isValidDomain(units[(e + 1)..<m], bare: false) { outcome = .email(end: m) }
                    break scan
                }
                guard isASCIILetter(units[j]) else { break scan }
                while j < count, isSchemeCharacter(units[j]) { j += 1 }
                guard j < count else { outcome = .pending(show: false); peek = count; break scan }
                peek = j
                if units[j] != colon {
                    // An opening tag: "<name>", "<name/>" or "<name />".
                    let name = String(decoding: units[(i + 1)..<j], as: UTF16.self).lowercased()
                    if let definition = tags[name] {
                        // A custom tag, which may have attributes.
                        switch scanAttributes(from: j, tagStart: i, in: units, count: count) {
                        case .tag(let attributes, let end):
                            outcome = .customTag(definition, attributes: attributes, end: end)
                            peek = end - 1
                        case .literal(let at):
                            peek = at
                        case .pending:
                            outcome = .pending(show: false)
                            peek = count
                        }
                        break scan
                    }
                    guard htmlTags[name] != nil || name == "br" else { break scan }
                    var k = j
                    while k < count, units[k] == space { k += 1 }
                    if k < count, units[k] == slash { k += 1 }
                    guard k < count else { outcome = .pending(show: false); peek = count; break scan }
                    peek = k
                    if units[k] == greaterThan { outcome = .tag(name: name, closing: false, end: k + 1) }
                    break scan
                }
                guard j - (i + 1) >= 2 else { break scan }
                let restStart = j + 1
                var k = restStart
                while k < count, units[k] != greaterThan, units[k] != lessThan,
                      !isWhitespace(Unicode.Scalar(units[k])) {
                    k += 1
                }
                guard k < count else { outcome = .pending(show: k > restStart); peek = count; break scan }
                peek = k
                if units[k] == greaterThan, k > restStart { outcome = .autolink(end: k) }
            }
            guard allowed(max(peek, emailPeek)) else { return false }
            switch outcome {
            case .autolink(let end):
                let target = units[(i + 1)..<end]
                let piece = state.appendSealedPiece(target)
                state.addSpan(from: piece, link: String(decoding: target, as: UTF16.self))
                state.position = end + 1
            case .email(let end):
                let address = units[(i + 1)..<end]
                let piece = state.appendSealedPiece(address)
                state.addSpan(from: piece, link: "mailto:" + String(decoding: address, as: UTF16.self))
                state.position = end + 1
            case .tag(let name, let closing, let end):
                if name == "br" {
                    state.appendText(CollectionOfOne(newline))
                } else if closing {
                    // Closes the innermost open tag of that name; a stray one is dropped.
                    if let index = state.tags.lastIndex(where: { $0.name == name }) {
                        let tag = state.tags[index]
                        state.addSpan(from: tag.piece + 1, traits: tag.traits, link: tag.custom?.decoration.link, customTag: tag.custom)
                        state.tags.remove(at: index)
                    }
                } else if let traits = htmlTags[name] {
                    let piece = state.appendSealedPiece(EmptyCollection<UInt16>())
                    state.tags.append(Tag(name: name, traits: traits, piece: piece))
                }
                state.position = end
            case .customTag(let definition, let attributes, let end):
                let decoration = definition.decoration(for: attributes)
                let custom = InlineSpan.CustomTag(name: definition.name, attributes: attributes, decoration: decoration)
                let piece = state.appendSealedPiece(EmptyCollection<UInt16>())
                state.tags.append(Tag(name: definition.name, traits: decoration.traits, piece: piece, custom: custom))
                state.position = end
            case .comment(let end):
                state.position = end
            case .pending(let show) where open:
                // An autolink still arriving: show it once it is certain, hide it until then.
                if show {
                    let target = units[(i + 1)..<count]
                    let piece = state.appendSealedPiece(target)
                    state.addSpan(from: piece, link: String(decoding: target, as: UTF16.self))
                }
                state.position = count
            case .literal, .pending:
                state.appendText(units[i..<(i + 1)])
                state.position = i + 1
            }

        case dollar:
            // "$$" … "$$" is display math. A single "$", as in a price, is text.
            guard i + 1 < count else {
                guard allowed(count) else { return false }
                state.appendText(units[i..<(i + 1)])
                state.position = i + 1
                return true
            }
            guard allowed(i + 1) else { return false }
            guard units[i + 1] == dollar else {
                state.appendText(units[i..<(i + 1)])
                state.position = i + 1
                return true
            }
            if let close = mathClose(from: i + 2, in: units, count: count, closer: nil) {
                guard allowed(close + 1) else { return false }
                takeMath(&state, units, opener: i, close: close, display: true)
                state.position = close + 2
                return true
            }
            guard allowed(count) else { return false }
            if open, count - i <= openMathReach {
                state.position = count
            } else {
                state.appendText(units[i..<(i + 2)])
                state.position = i + 2
            }

        case ampersand:
            let scan = scanEntity(at: i, in: units, count: count)
            if case .incomplete = scan {
                guard allowed(count) else { return false }
            } else if case .match(let length, _) = scan {
                guard allowed(i + length - 1) else { return false }
            } else {
                // Decided at the unit that ruled it out, at most a name's length on.
                guard allowed(min(i + longestEntityName + 3, count)) else { return false }
            }
            if case .match(let length, let value) = scan {
                state.appendText(value)
                state.position = i + length
            } else {
                state.appendText(units[i..<(i + 1)])
                state.position = i + 1
            }

        default:
            var end = i + 1
            while end < count, !isSpecial(units[end]) { end += 1 }
            if let limit {
                end = min(end, limit)
                // The word at the stable boundary may still turn out to be an
                // email address once an "@" arrives, so it is not committed.
                // Addresses are at most 254 characters, so a longer run (a
                // pasted hash, say) is committed and not parsed again.
                if limit > 0, isBareEmailLocal(units[limit - 1]) {
                    var wordStart = limit - 1
                    while wordStart > 0, limit - wordStart < 256, isBareEmailLocal(units[wordStart - 1]) { wordStart -= 1 }
                    if limit - wordStart < 256 { end = min(end, max(i, wordStart)) }
                }
            }
            // A bare URL ("https://...", "www...") somewhere in the run. Not
            // inside link text, which would make a link within a link.
            if state.brackets.isEmpty {
                let bound = limit ?? count
                var j = i
                search: while j < end {
                    if units[j] == 0x68 || units[j] == 0x77, j == 0 || canPrecedeAutolink(units[j - 1]) { // h, w
                        switch urlPrefixLength(at: j, in: units, bound: bound) {
                        case .some(let length) where length > 0:
                            if j == i {
                                return takeBareURL(&state, units, at: i, prefixLength: length, count: count, limit: limit)
                            }
                            end = j
                            break search
                        case .some:
                            break
                        case .none:
                            // Cannot tell yet: in the stable pass, stop before it.
                            if limit != nil {
                                end = j
                                break search
                            }
                        }
                    }
                    // A bare email address, found from the start of its word.
                    if emails, isBareEmailLocal(units[j]), j == 0 || (!isBareEmailLocal(units[j - 1]) && units[j - 1] != atSign) {
                        switch bareEmail(at: j, in: units, bound: bound, isEnd: limit == nil) {
                        case .match(let emailEnd):
                            if j == i {
                                let address = units[i..<emailEnd]
                                let piece = state.appendSealedPiece(address)
                                state.addSpan(from: piece, link: "mailto:" + String(decoding: address, as: UTF16.self))
                                state.position = emailEnd
                                return true
                            }
                            end = j
                            break search
                        case .undecided:
                            end = j
                            break search
                        case .noMatch:
                            break
                        }
                    }
                    j += 1
                }
            }
            guard end > i else { return false }
            state.appendText(units[i..<end])
            state.position = end
        }
        return true
    }

    // MARK: Math

    /// Where the closing delimiter starts after `start`: `\` then `closer`, or
    /// "$$" when `closer` is nil. A backslash escapes the unit after it, so
    /// "\\)" (a LaTeX line break, then ")") does not close.
    private static func mathClose(from start: Int, in units: [UInt16], count: Int, closer: UInt16?) -> Int? {
        var k = start
        while k + 1 < count {
            if units[k] == backslash {
                if let closer, units[k + 1] == closer { return k }
                k += 2
                continue
            }
            if closer == nil, units[k] == dollar, units[k + 1] == dollar { return k }
            k += 1
        }
        return nil
    }

    /// A formula, kept whole: its LaTeX is not parsed as Markdown. An empty
    /// one shows as written.
    private static func takeMath(_ state: inout Checkpoint, _ units: [UInt16], opener: Int, close: Int, display: Bool) {
        let tex = String(decoding: units[(opener + 2)..<close], as: UTF16.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tex.isEmpty else {
            state.appendText(units[opener..<(close + 2)])
            return
        }
        let piece = state.appendSealedPiece(CollectionOfOne(objectReplacement))
        state.addSpan(from: piece, math: TranscriptMath(tex: tex, isDisplay: display))
    }

    // MARK: Custom tags

    private enum AttributeScan {
        case tag(attributes: [String: String], end: Int)
        /// Not a tag, which the unit at `at` decided.
        case literal(at: Int)
        /// The text ends before it is decided.
        case pending
    }

    private static let equals = UInt16(UInt8(ascii: "="))
    private static let doubleQuote = UInt16(UInt8(ascii: "\""))
    private static let singleQuote = UInt16(UInt8(ascii: "'"))
    private static let tab = UInt16(UInt8(ascii: "\t"))
    /// Units that can't be in an unquoted attribute value, besides whitespace and ">".
    private static let unquotedValueStops = Set("\"'=<`".utf16)

    private static func isTagSpace(_ unit: UInt16) -> Bool {
        unit == space || unit == tab || unit == newline
    }

    private static func isAttributeNameStart(_ unit: UInt16) -> Bool {
        isASCIILetter(unit) || unit == underscore || unit == colon
    }

    private static func isAttributeNameCharacter(_ unit: UInt16) -> Bool {
        isAttributeNameStart(unit) || isASCIIDigit(unit) || unit == dot || unit == dash
    }

    /// Reads the rest of an opening custom tag from `start`, just after its
    /// name: attributes (`name="value"`, `name='value'` or `name=value`),
    /// then ">" or "/>". Looks at no unit past `maximumTagLength` from the
    /// tag's "<", so a long one is decided the same way however the text
    /// arrives.
    private static func scanAttributes(from start: Int, tagStart: Int, in units: [UInt16], count: Int) -> AttributeScan {
        let bound = min(count, tagStart + maximumTagLength)
        // Out of units: the tag may still end, unless it is already too long.
        let outOfUnits: AttributeScan = bound == count && count - tagStart < maximumTagLength ? .pending : .literal(at: bound - 1)
        var attributes: [String: String] = [:]
        var k = start
        while true {
            var sawSpace = false
            while k < bound, isTagSpace(units[k]) {
                k += 1
                sawSpace = true
            }
            guard k < bound else { return outOfUnits }
            if units[k] == greaterThan { return .tag(attributes: attributes, end: k + 1) }
            if units[k] == slash {
                guard k + 1 < bound else { return outOfUnits }
                return units[k + 1] == greaterThan ? .tag(attributes: attributes, end: k + 2) : .literal(at: k + 1)
            }
            // An attribute, after whitespace.
            guard sawSpace, isAttributeNameStart(units[k]) else { return .literal(at: k) }
            let nameStart = k
            while k < bound, isAttributeNameCharacter(units[k]) { k += 1 }
            let name = String(decoding: units[nameStart..<k], as: UTF16.self).lowercased()
            while k < bound, isTagSpace(units[k]) { k += 1 }
            guard k < bound else { return outOfUnits }
            // Always with a value: a bare name would let prose after a tag's
            // name ("<note this is ...") pass for attributes, hidden while it streams.
            guard units[k] == equals else { return .literal(at: k) }
            k += 1
            while k < bound, isTagSpace(units[k]) { k += 1 }
            guard k < bound else { return outOfUnits }
            let value: ArraySlice<UInt16>
            if units[k] == doubleQuote || units[k] == singleQuote {
                let quote = units[k]
                let valueStart = k + 1
                k = valueStart
                while k < bound, units[k] != quote { k += 1 }
                guard k < bound else { return outOfUnits }
                value = units[valueStart..<k]
                k += 1
                guard k < bound else { return outOfUnits }
                guard isTagSpace(units[k]) || units[k] == greaterThan || units[k] == slash else { return .literal(at: k) }
            } else {
                let valueStart = k
                while k < bound, !isTagSpace(units[k]), units[k] != greaterThan, !unquotedValueStops.contains(units[k]) { k += 1 }
                guard k < bound else { return outOfUnits }
                guard k > valueStart, isTagSpace(units[k]) || units[k] == greaterThan else { return .literal(at: k) }
                value = units[valueStart..<k]
            }
            // The first of two with the same name counts, as in HTML.
            if attributes[name] == nil { attributes[name] = String(decoding: value, as: UTF16.self) }
        }
    }

    /// The HTML tags that are rendered, and the style each applies. `<br>`
    /// is a line break.
    private static let htmlTags: [String: InlineSpan.Traits] = [
        "b": .bold, "strong": .bold, "i": .italic, "em": .italic, "u": .underline,
        "s": .strikethrough, "del": .strikethrough, "strike": .strikethrough,
        "code": .code, "kbd": .code,
    ]

    // MARK: Email addresses

    /// CommonMark's characters for the part before the "@" in "<local@domain>".
    private static func isBracketedEmailLocal(_ unit: UInt16) -> Bool {
        isASCIILetter(unit) || isASCIIDigit(unit) || "!#$%&'*+/=?^_`{|}~-.".utf16.contains(unit)
    }

    /// GFM's characters for the part before the "@" of a bare address.
    private static func isBareEmailLocal(_ unit: UInt16) -> Bool {
        isASCIILetter(unit) || isASCIIDigit(unit) || unit == dot || unit == dash || unit == underscore || unit == 0x2B // +
    }

    /// Labels of letters, digits and hyphens (and "_" in a bare address),
    /// separated by dots. A bare address needs at least one dot and may not
    /// end in "-" or "_".
    private static func isValidDomain(_ domain: ArraySlice<UInt16>, bare: Bool) -> Bool {
        guard !domain.isEmpty else { return false }
        let labels = domain.split(separator: dot, omittingEmptySubsequences: false)
        guard labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 }) else { return false }
        if bare {
            guard labels.count >= 2, let last = domain.last, last != dash, last != underscore else { return false }
            return true
        }
        return labels.allSatisfy { $0.first != dash && $0.last != dash }
    }

    private enum EmailScan {
        case match(end: Int)
        case noMatch
        /// The units before `bound` cannot tell yet.
        case undecided
    }

    /// A bare email address starting at `j`, such as "support@example.com".
    /// - Parameter isEnd: `bound` is the end of the text, so an address that
    ///   reaches it is taken as it is so far.
    private static func bareEmail(at j: Int, in units: [UInt16], bound: Int, isEnd: Bool) -> EmailScan {
        var k = j
        while k < bound, k - j < 256, isBareEmailLocal(units[k]) { k += 1 }
        // Longer than any address: the stable pass commits such a run (see `step`).
        guard k - j < 256 else { return .noMatch }
        guard k < bound else { return isEnd ? .noMatch : .undecided }
        guard units[k] == atSign, k > j else { return .noMatch }
        var m = k + 1
        while m < bound, isASCIILetter(units[m]) || isASCIIDigit(units[m]) || units[m] == dash || units[m] == underscore || units[m] == dot {
            m += 1
        }
        if m >= bound, !isEnd { return .undecided }
        var end = m
        // A dot at the end ends the sentence, not the address.
        while end > k + 1, units[end - 1] == dot { end -= 1 }
        return isValidDomain(units[(k + 1)..<end], bare: true) ? .match(end: end) : .noMatch
    }

    // MARK: Bare URLs

    /// GFM's rule: an autolink starts a line, or follows whitespace or one of `*_~(`.
    private static func canPrecedeAutolink(_ unit: UInt16) -> Bool {
        unit == space || unit == newline || unit == 0x09 || unit == star || unit == underscore || unit == tilde || unit == openParen
    }

    private static let urlPrefixes: [[UInt16]] = ["https://", "http://", "www."].map { Array($0.utf16) }

    /// The length of the URL prefix at `j`, 0 if there is none, or nil if
    /// the units before `bound` cannot tell yet.
    private static func urlPrefixLength(at j: Int, in units: [UInt16], bound: Int) -> Int? {
        var undecided = false
        for prefix in urlPrefixes {
            var k = 0
            while k < prefix.count, j + k < bound, units[j + k] == prefix[k] { k += 1 }
            if k == prefix.count {
                // Something must follow the prefix.
                guard j + k < bound else { undecided = true; continue }
                if !isWhitespace(Unicode.Scalar(units[j + k])), units[j + k] != lessThan { return k }
            } else if j + k >= bound {
                undecided = true
            }
        }
        return undecided ? nil : 0
    }

    /// Takes a bare URL at `i`: up to whitespace or "<", without trailing
    /// punctuation or an unbalanced ")".
    private static func takeBareURL(_ state: inout Checkpoint, _ units: [UInt16], at i: Int, prefixLength: Int,
                                    count: Int, limit: Int?) -> Bool {
        var k = i + prefixLength
        while k < count, !isWhitespace(Unicode.Scalar(units[k])), units[k] != lessThan { k += 1 }
        // Where it ends is not known until a unit after it arrives.
        if let limit, k >= limit { return false }
        var end = k
        let trailing = Set("?!.,:*_~'\"".utf16)
        while end > i + prefixLength {
            let last = units[end - 1]
            if trailing.contains(last) {
                end -= 1
            } else if last == closeParen {
                let opens = units[i..<end].filter { $0 == openParen }.count
                let closes = units[i..<end].filter { $0 == closeParen }.count
                guard closes > opens else { break }
                end -= 1
            } else if last == semicolon, let amp = units[i..<end].lastIndex(of: ampersand),
                      units[(amp + 1)..<(end - 1)].allSatisfy({ isASCIILetter($0) || isASCIIDigit($0) }), amp + 1 < end - 1 {
                // "&quot;" and the like at the end are not part of it.
                end = amp
            } else {
                break
            }
        }
        guard end > i + prefixLength else {
            state.appendText(units[i..<(i + 1)])
            state.position = i + 1
            return true
        }
        let target = units[i..<end]
        var destination = String(decoding: target, as: UTF16.self)
        if units[i] == 0x77 { destination = "http://" + destination } // www.
        let piece = state.appendSealedPiece(target)
        state.addSpan(from: piece, link: destination)
        state.position = end
        return true
    }

    private static func traits(for character: UInt16, count: Int) -> InlineSpan.Traits {
        if character == tilde { return .strikethrough }
        switch count {
        case 1: return .italic
        case 2: return .bold
        default: return [.bold, .italic]
        }
    }

    /// Unclosed markup is treated as closing at the end of the text.
    private static func closeAtEnd(_ state: inout Checkpoint, count: Int) {
        for delimiter in state.delimiters {
            state.pieces[delimiter.piece].length = 0
            state.spans.append(PendingSpan(
                from: delimiter.piece + 1, to: state.pieces.count,
                traits: traits(for: delimiter.character, count: delimiter.count), link: nil
            ))
        }
        for bracket in state.brackets {
            // An image still arriving shows nothing, nor anything after it,
            // and neither does a recent "[" that may yet be a link.
            if bracket.isImage || count - bracket.sourceStart <= openBracketReach {
                state.hide(from: bracket.piece)
                break
            }
        }
    }
}

private extension InlineParser.Checkpoint {
    mutating func appendText<C: Collection>(_ units: C) where C.Element == UInt16 {
        guard !units.isEmpty else { return }
        if lastPieceIsOpenText {
            pieces[pieces.count - 1].length += units.count
        } else {
            pieces.append(InlineParser.Piece(start: output.count, length: units.count))
            lastPieceIsOpenText = true
        }
        output.append(contentsOf: units)
    }

    mutating func appendText(repeating unit: UInt16, count: Int) {
        appendText(repeatElement(unit, count: count))
    }

    mutating func appendSealedPiece<C: Collection>(_ units: C) -> Int where C.Element == UInt16 {
        pieces.append(InlineParser.Piece(start: output.count, length: units.count))
        output.append(contentsOf: units)
        lastPieceIsOpenText = false
        return pieces.count - 1
    }

    mutating func appendSealedPiece(repeating unit: UInt16, count: Int) -> Int {
        appendSealedPiece(repeatElement(unit, count: count))
    }

    mutating func addSpan(from: Int, traits: InlineSpan.Traits = [], link: String? = nil, image: TranscriptImage? = nil,
                          reference: String? = nil, customTag: InlineSpan.CustomTag? = nil, math: TranscriptMath? = nil) {
        spans.append(InlineParser.PendingSpan(from: from, to: pieces.count, traits: traits, link: link, image: image,
                                              reference: reference, customTag: customTag, math: math))
        lastPieceIsOpenText = false
    }

    /// Empties every piece from `piece` on.
    mutating func hide(from piece: Int) {
        for index in piece..<pieces.count { pieces[index].length = 0 }
        // The last piece no longer ends at the end of `output`.
        lastPieceIsOpenText = false
    }

    /// The text of the pieces from `piece` on.
    func plainText(from piece: Int) -> String {
        var units: [UInt16] = []
        for index in piece..<pieces.count {
            units.append(contentsOf: output[pieces[index].start..<(pieces[index].start + pieces[index].length)])
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// Spans in result order: by start, longer first, then in the order
    /// they were made. Total, so that building the result in parts gives the
    /// same order as building it at once.
    private static func precedes(_ a: (span: InlineSpan, index: Int), _ b: (span: InlineSpan, index: Int)) -> Bool {
        if a.span.range.lowerBound != b.span.range.lowerBound { return a.span.range.lowerBound < b.span.range.lowerBound }
        if a.span.range.upperBound != b.span.range.upperBound { return a.span.range.upperBound > b.span.range.upperBound }
        return a.index < b.index
    }

    /// The pieces from the first that may still change, as a boundary.
    ///
    /// Open tags don't count: a tag's piece is empty and stays so, and
    /// closing it only adds a span, which `result()` merges in. Counting them
    /// made every update inside a long tag build its whole text again.
    private var changeablePiece: Int {
        var boundary = lastPieceIsOpenText ? pieces.count - 1 : pieces.count
        for delimiter in delimiters { boundary = min(boundary, delimiter.piece) }
        for bracket in brackets { boundary = min(boundary, bracket.piece) }
        return max(boundary, 0)
    }

    /// Two lists sorted by `precedes`, as one sorted list.
    private static func merged(_ a: [(span: InlineSpan, index: Int)], _ b: [(span: InlineSpan, index: Int)])
        -> [(span: InlineSpan, index: Int)] {
        var result: [(span: InlineSpan, index: Int)] = []
        result.reserveCapacity(a.count + b.count)
        var i = 0
        var j = 0
        while i < a.count, j < b.count {
            if precedes(b[j], a[i]) {
                result.append(b[j])
                j += 1
            } else {
                result.append(a[i])
                i += 1
            }
        }
        result.append(contentsOf: a[i...])
        result.append(contentsOf: b[j...])
        return result
    }

    /// Adds the pieces that can no longer change to the settled result.
    /// Called on the checkpoint after its stable decisions, so every parse
    /// that resumes from it reuses that text and those spans.
    mutating func settle() {
        var boundary = changeablePiece
        guard boundary > settledPieces else { return }
        var units: [UInt16] = []
        var offsets: [Int] = []
        let base = settledOffsets[settledOffsets.count - 1]
        for index in settledPieces..<boundary {
            let piece = pieces[index]
            units.append(contentsOf: output[piece.start..<(piece.start + piece.length)])
            offsets.append(base + units.count)
        }
        // Never end the settled text inside a surrogate pair: the halves
        // would be decoded apart.
        while boundary > settledPieces, let last = units.last, UTF16.isLeadSurrogate(last) {
            boundary -= 1
            offsets.removeLast()
            units.removeLast(units.count - ((offsets.last ?? base) - base))
        }
        guard boundary > settledPieces else { return }
        settledText += String(decoding: units, as: UTF16.self)
        settledOffsets += offsets
        settledPieces = boundary
        // Spans end in the order they are made, so the settled ones come first.
        var newlySettled: [(span: InlineSpan, index: Int)] = []
        while settledSpanCount < spans.count, spans[settledSpanCount].to <= settledPieces {
            let pending = spans[settledSpanCount]
            let span = pending.span(settledOffsets[pending.from]..<settledOffsets[pending.to])
            if !span.range.isEmpty { newlySettled.append((span, settledSpanCount)) }
            settledSpanCount += 1
        }
        if !newlySettled.isEmpty {
            newlySettled.sort(by: Self.precedes)
            if let first = newlySettled.first, let last = settledSpans.last, Self.precedes(first, last) {
                settledSpans = Self.merged(settledSpans, newlySettled)
                settledSpanList = settledSpans.map(\.span)
            } else {
                settledSpans += newlySettled
                settledSpanList += newlySettled.map(\.span)
            }
        }
    }

    func result() -> InlineParser.Result {
        // The settled part as it was; only what comes after it is made here.
        let base = settledOffsets[settledOffsets.count - 1]
        var offsets: [Int] = []
        offsets.reserveCapacity(pieces.count - settledPieces)
        var text: [UInt16] = []
        for index in settledPieces..<pieces.count {
            let piece = pieces[index]
            text.append(contentsOf: output[piece.start..<(piece.start + piece.length)])
            offsets.append(base + text.count)
        }
        func offset(_ piece: Int) -> Int {
            piece <= settledPieces ? settledOffsets[piece] : offsets[piece - settledPieces - 1]
        }
        var newer: [(span: InlineSpan, index: Int)] = []
        for index in settledSpanCount..<spans.count {
            let pending = spans[index]
            let span = pending.span(offset(pending.from)..<offset(pending.to))
            if !span.range.isEmpty { newer.append((span, index)) }
        }
        newer.sort(by: Self.precedes)
        let resolved: [InlineSpan]
        if let first = newer.first, let last = settledSpans.last, Self.precedes(first, last) {
            // A span still open when the rest settled can start inside it
            // ("*a [b* c"), as can the span of a tag opened before it. Each
            // is put in its place; usually there are only one or two.
            var list: [InlineSpan] = []
            list.reserveCapacity(settledSpanList.count + newer.count)
            var start = 0
            for entry in newer {
                var low = start
                var high = settledSpans.count
                while low < high {
                    let mid = (low + high) / 2
                    if Self.precedes(entry, settledSpans[mid]) { high = mid } else { low = mid + 1 }
                }
                list.append(contentsOf: settledSpanList[start..<low])
                list.append(entry.span)
                start = low
            }
            list.append(contentsOf: settledSpanList[start...])
            resolved = list
        } else {
            var list = settledSpanList
            list.reserveCapacity(list.count + newer.count)
            for entry in newer { list.append(entry.span) }
            resolved = list
        }
        let result = InlineParser.Result(text: settledText + String(decoding: text, as: UTF16.self), spans: resolved)
        #if DEBUG
        if InlineParser.checksSettledResult {
            assert(result == fullResult(), "The settled part of an inline parse changed")
        }
        #endif
        return result
    }

    /// The result built from every piece, without the settled part: what
    /// `result()` must equal. For checking it in debug builds.
    func fullResult() -> InlineParser.Result {
        var offsets: [Int] = [0]
        var text: [UInt16] = []
        for piece in pieces {
            text.append(contentsOf: output[piece.start..<(piece.start + piece.length)])
            offsets.append(text.count)
        }
        let resolved = spans.enumerated()
            .map { (span: $0.element.span(offsets[$0.element.from]..<offsets[$0.element.to]), index: $0.offset) }
            .filter { !$0.span.range.isEmpty }
            .sorted(by: Self.precedes)
            .map(\.span)
        return InlineParser.Result(text: String(decoding: text, as: UTF16.self), spans: resolved)
    }
}
