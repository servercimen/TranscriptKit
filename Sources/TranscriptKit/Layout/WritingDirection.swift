import CoreText
import Foundation

/// The base direction of a paragraph's text.
enum WritingDirection: Sendable {
    case leftToRight
    case rightToLeft

    // Core Text paragraph styles are immutable.
    nonisolated(unsafe) private static let leftToRightStyle = makeParagraphStyle(.leftToRight)
    nonisolated(unsafe) private static let rightToLeftStyle = makeParagraphStyle(.rightToLeft)

    /// A Core Text paragraph style with this base direction, which the
    /// typesetter then uses for every line, also for a line typeset from
    /// the middle of the paragraph.
    var paragraphStyle: CTParagraphStyle {
        self == .rightToLeft ? Self.rightToLeftStyle : Self.leftToRightStyle
    }

    private static func makeParagraphStyle(_ direction: CTWritingDirection) -> CTParagraphStyle {
        var value = direction
        return withUnsafeBytes(of: &value) { bytes in
            var setting = CTParagraphStyleSetting(spec: .baseWritingDirection, valueSize: MemoryLayout<CTWritingDirection>.size,
                                                  value: bytes.baseAddress!)
            return CTParagraphStyleCreate(&setting, 1)
        }
    }
}

/// What a scan of a text found about its direction, so far: the direction
/// of its first strong character (the natural base direction, as the
/// Unicode bidirectional algorithm finds it), and whether it holds any
/// right-to-left character.
///
/// A scan goes on from where it stopped, so text that grows by appends is
/// not read again.
struct DirectionScan: Equatable, Sendable {
    private(set) var firstStrong: WritingDirection?
    private(set) var hasRightToLeft = false
    /// The UTF-16 length of the text scanned.
    private(set) var length = 0
    /// How many isolates (U+2066 to U+2068) are open: the first strong
    /// character is not looked for inside them.
    private var isolates = 0

    init() {}

    init(_ text: String) {
        scan(text)
    }

    /// The direction to set on the text when it is typeset: nil when it has
    /// no right-to-left character, as Core Text then lays it out from the
    /// left without being told.
    var paragraphDirection: WritingDirection? {
        hasRightToLeft ? (firstStrong ?? .leftToRight) : nil
    }

    /// Scans `text` from `length`, the end of the text scanned before. The
    /// text before it must not have changed.
    mutating func scan(_ text: String) {
        let utf16 = text.utf16
        guard utf16.count > length else { return }
        guard firstStrong == nil || !hasRightToLeft else {
            length = utf16.count
            return
        }
        var index = utf16.index(utf16.startIndex, offsetBy: length)
        while index < utf16.endIndex {
            var value = UInt32(utf16[index])
            utf16.formIndex(after: &index)
            if UTF16.isLeadSurrogate(UInt16(value)), index < utf16.endIndex, UTF16.isTrailSurrogate(utf16[index]) {
                value = 0x10000 + ((value - 0xD800) << 10) + (UInt32(utf16[index]) - 0xDC00)
                utf16.formIndex(after: &index)
            }
            guard let scalar = Unicode.Scalar(value) else { continue }
            if Self.isRightToLeftCharacter(scalar) { hasRightToLeft = true }
            if firstStrong == nil {
                switch value {
                case 0x2066...0x2068: isolates += 1
                case 0x2069: isolates = max(isolates - 1, 0)
                default:
                    if isolates == 0 { firstStrong = Self.strongDirection(of: scalar) }
                }
            }
            if firstStrong != nil, hasRightToLeft { break }
        }
        length = utf16.count
    }

    /// Whether the scalar belongs to a right-to-left script, or is a mark or
    /// control that makes text right-to-left.
    static func isRightToLeftCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF: return true
        case 0x200F, 0x202B, 0x202E, 0x2067: return true
        default: return false
        }
    }

    /// The direction of a strong character, or nil for one that takes its
    /// direction from the text around it: digits, punctuation, spaces,
    /// symbols and marks.
    static func strongDirection(of scalar: Unicode.Scalar) -> WritingDirection? {
        switch scalar.value {
        case 0x200E: return .leftToRight
        case 0x200F, 0x061C: return .rightToLeft
        // Arabic punctuation and signs that are weak or neutral.
        case 0x0600...0x0605, 0x0609, 0x060A, 0x060C, 0x066A...0x066C, 0x06DD, 0x06E9, 0x08E2: return nil
        default: break
        }
        let category = scalar.properties.generalCategory
        if isRightToLeftCharacter(scalar) {
            switch category {
            case .nonspacingMark, .enclosingMark, .decimalNumber, .format, .control: return nil
            default: return .rightToLeft
            }
        }
        switch category {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .spacingMark:
            return .leftToRight
        default:
            return nil
        }
    }
}
