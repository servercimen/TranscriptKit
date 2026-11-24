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
        case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFE, 0x10800...0x10FFF, 0x1E800...0x1EFFF: return true
        case 0x200F, 0x202B, 0x202E, 0x2067: return true
        default: return false
        }
    }

    /// The direction of a strong character, or nil for one that takes its
    /// direction from the text around it: digits, punctuation, spaces,
    /// symbols and marks. This is the bidirectional class of the character
    /// (L, or R and AL).
    static func strongDirection(of scalar: Unicode.Scalar) -> WritingDirection? {
        if let exception = exception(for: scalar.value) { return exception.direction }
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
    private static func exception(for value: UInt32) -> (lower: UInt32, upper: UInt32, direction: WritingDirection?)? {
        var low = 0
        var high = exceptions.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let entry = exceptions[mid]
            if value < entry.lower {
                high = mid - 1
            } else if value > entry.upper {
                low = mid + 1
            } else {
                return entry
            }
        }
        return nil
    }

    /// The assigned characters, in ranges, whose bidirectional class in
    /// Unicode 16.0 is not the one that `strongDirection(of:)` finds from
    /// the general category: for example Roman numerals, regional
    /// indicators, private use characters and the digits of Indic scripts
    /// are L, and some modifier letters are neutral.
    private static let exceptions: [(lower: UInt32, upper: UInt32, direction: WritingDirection?)] = [
        (0x02B9, 0x02BA, nil), (0x02C6, 0x02CF, nil), (0x02EC, 0x02EC, nil), (0x0374, 0x0374, nil),
        (0x0482, 0x0482, .leftToRight), (0x055A, 0x055F, .leftToRight), (0x0589, 0x0589, .leftToRight), (0x0606, 0x0607, nil),
        (0x060E, 0x060F, nil), (0x06DE, 0x06DE, nil), (0x070F, 0x070F, .rightToLeft), (0x07C0, 0x07C9, .rightToLeft),
        (0x07F6, 0x07F9, nil), (0x0964, 0x0970, .leftToRight), (0x09E6, 0x09EF, .leftToRight), (0x09F4, 0x09FA, .leftToRight),
        (0x09FD, 0x09FD, .leftToRight), (0x0A66, 0x0A6F, .leftToRight), (0x0A76, 0x0A76, .leftToRight),
        (0x0AE6, 0x0AF0, .leftToRight), (0x0B66, 0x0B70, .leftToRight), (0x0B72, 0x0B77, .leftToRight),
        (0x0BE6, 0x0BF2, .leftToRight), (0x0C66, 0x0C6F, .leftToRight), (0x0C77, 0x0C77, .leftToRight),
        (0x0C7F, 0x0C7F, .leftToRight), (0x0C84, 0x0C84, .leftToRight), (0x0CBF, 0x0CBF, .leftToRight),
        (0x0CC6, 0x0CC6, .leftToRight), (0x0CE6, 0x0CEF, .leftToRight), (0x0D4F, 0x0D4F, .leftToRight),
        (0x0D58, 0x0D5E, .leftToRight), (0x0D66, 0x0D79, .leftToRight), (0x0DE6, 0x0DEF, .leftToRight),
        (0x0DF4, 0x0DF4, .leftToRight), (0x0E4F, 0x0E5B, .leftToRight), (0x0ED0, 0x0ED9, .leftToRight),
        (0x0F01, 0x0F17, .leftToRight), (0x0F1A, 0x0F34, .leftToRight), (0x0F36, 0x0F36, .leftToRight),
        (0x0F38, 0x0F38, .leftToRight), (0x0F85, 0x0F85, .leftToRight), (0x0FBE, 0x0FC5, .leftToRight),
        (0x0FC7, 0x0FCC, .leftToRight), (0x0FCE, 0x0FDA, .leftToRight), (0x1040, 0x104F, .leftToRight),
        (0x1090, 0x1099, .leftToRight), (0x109E, 0x109F, .leftToRight), (0x10FB, 0x10FB, .leftToRight),
        (0x1360, 0x137C, .leftToRight), (0x166D, 0x166E, .leftToRight), (0x16EB, 0x16F0, .leftToRight),
        (0x1735, 0x1736, .leftToRight), (0x17D4, 0x17D6, .leftToRight), (0x17D8, 0x17DA, .leftToRight),
        (0x17E0, 0x17E9, .leftToRight), (0x1810, 0x1819, .leftToRight), (0x1946, 0x194F, .leftToRight),
        (0x19D0, 0x19DA, .leftToRight), (0x1A1E, 0x1A1F, .leftToRight), (0x1A80, 0x1A89, .leftToRight),
        (0x1A90, 0x1A99, .leftToRight), (0x1AA0, 0x1AA6, .leftToRight), (0x1AA8, 0x1AAD, .leftToRight),
        (0x1B4E, 0x1B6A, .leftToRight), (0x1B74, 0x1B7F, .leftToRight), (0x1BB0, 0x1BB9, .leftToRight),
        (0x1BFC, 0x1BFF, .leftToRight), (0x1C3B, 0x1C49, .leftToRight), (0x1C50, 0x1C59, .leftToRight),
        (0x1C7E, 0x1C7F, .leftToRight), (0x1CC0, 0x1CC7, .leftToRight), (0x1CD3, 0x1CD3, .leftToRight),
        (0x214F, 0x214F, .leftToRight), (0x2160, 0x2182, .leftToRight), (0x2185, 0x2188, .leftToRight),
        (0x2336, 0x237A, .leftToRight), (0x2395, 0x2395, .leftToRight), (0x249C, 0x24E9, .leftToRight),
        (0x26AC, 0x26AC, .leftToRight), (0x2800, 0x28FF, .leftToRight), (0x2D70, 0x2D70, .leftToRight), (0x2E2F, 0x2E2F, nil),
        (0x3007, 0x3007, .leftToRight), (0x3021, 0x3029, .leftToRight), (0x3038, 0x303A, .leftToRight),
        (0x3190, 0x319F, .leftToRight), (0x3200, 0x321C, .leftToRight), (0x3220, 0x324F, .leftToRight),
        (0x3260, 0x327B, .leftToRight), (0x327F, 0x32B0, .leftToRight), (0x32C0, 0x32CB, .leftToRight),
        (0x32D0, 0x3376, .leftToRight), (0x337B, 0x33DD, .leftToRight), (0x33E0, 0x33FE, .leftToRight),
        (0xA4FE, 0xA4FF, .leftToRight), (0xA620, 0xA629, .leftToRight), (0xA67F, 0xA67F, nil), (0xA6E6, 0xA6EF, .leftToRight),
        (0xA6F2, 0xA6F7, .leftToRight), (0xA717, 0xA71F, nil), (0xA788, 0xA788, nil), (0xA789, 0xA78A, .leftToRight),
        (0xA830, 0xA837, .leftToRight), (0xA8CE, 0xA8D9, .leftToRight), (0xA8F8, 0xA8FA, .leftToRight),
        (0xA8FC, 0xA8FC, .leftToRight), (0xA900, 0xA909, .leftToRight), (0xA92E, 0xA92F, .leftToRight),
        (0xA95F, 0xA95F, .leftToRight), (0xA9C1, 0xA9CD, .leftToRight), (0xA9D0, 0xA9D9, .leftToRight),
        (0xA9DE, 0xA9DF, .leftToRight), (0xA9F0, 0xA9F9, .leftToRight), (0xAA50, 0xAA59, .leftToRight),
        (0xAA5C, 0xAA5F, .leftToRight), (0xAA77, 0xAA79, .leftToRight), (0xAADE, 0xAADF, .leftToRight),
        (0xAAF0, 0xAAF1, .leftToRight), (0xAB5B, 0xAB5B, .leftToRight), (0xABEB, 0xABEB, .leftToRight),
        (0xABF0, 0xABF9, .leftToRight), (0xE000, 0xF8FF, .leftToRight), (0xFB29, 0xFB29, nil), (0xFD3E, 0xFD4F, nil),
        (0xFDCF, 0xFDCF, nil), (0xFDFD, 0xFDFF, nil), (0x10100, 0x10100, .leftToRight), (0x10102, 0x10102, .leftToRight),
        (0x10107, 0x10133, .leftToRight), (0x10137, 0x1013F, .leftToRight), (0x1018D, 0x1018E, .leftToRight),
        (0x101D0, 0x101FC, .leftToRight), (0x10320, 0x10323, .leftToRight), (0x10341, 0x10341, .leftToRight),
        (0x1034A, 0x1034A, .leftToRight), (0x1039F, 0x1039F, .leftToRight), (0x103D0, 0x103D5, .leftToRight),
        (0x104A0, 0x104A9, .leftToRight), (0x1056F, 0x1056F, .leftToRight), (0x1091F, 0x1091F, nil), (0x10B39, 0x10B3F, nil),
        (0x10D6E, 0x10D6E, nil), (0x10E60, 0x10E7E, nil), (0x11047, 0x1104D, .leftToRight), (0x11066, 0x1106F, .leftToRight),
        (0x110BB, 0x110C1, .leftToRight), (0x110CD, 0x110CD, .leftToRight), (0x110F0, 0x110F9, .leftToRight),
        (0x11136, 0x11143, .leftToRight), (0x11174, 0x11175, .leftToRight), (0x111C5, 0x111C8, .leftToRight),
        (0x111CD, 0x111CD, .leftToRight), (0x111D0, 0x111D9, .leftToRight), (0x111DB, 0x111DB, .leftToRight),
        (0x111DD, 0x111DF, .leftToRight), (0x111E1, 0x111F4, .leftToRight), (0x11238, 0x1123D, .leftToRight),
        (0x112A9, 0x112A9, .leftToRight), (0x112F0, 0x112F9, .leftToRight), (0x113D4, 0x113D5, .leftToRight),
        (0x113D7, 0x113D8, .leftToRight), (0x1144B, 0x1145B, .leftToRight), (0x1145D, 0x1145D, .leftToRight),
        (0x114C6, 0x114C6, .leftToRight), (0x114D0, 0x114D9, .leftToRight), (0x115C1, 0x115D7, .leftToRight),
        (0x11641, 0x11643, .leftToRight), (0x11650, 0x11659, .leftToRight), (0x116B9, 0x116B9, .leftToRight),
        (0x116C0, 0x116C9, .leftToRight), (0x116D0, 0x116E3, .leftToRight), (0x11730, 0x1173F, .leftToRight),
        (0x1183B, 0x1183B, .leftToRight), (0x118E0, 0x118F2, .leftToRight), (0x11944, 0x11946, .leftToRight),
        (0x11950, 0x11959, .leftToRight), (0x119E2, 0x119E2, .leftToRight), (0x11A07, 0x11A08, .leftToRight),
        (0x11A3F, 0x11A46, .leftToRight), (0x11A9A, 0x11A9C, .leftToRight), (0x11A9E, 0x11AA2, .leftToRight),
        (0x11B00, 0x11B09, .leftToRight), (0x11BE1, 0x11BE1, .leftToRight), (0x11BF0, 0x11BF9, .leftToRight),
        (0x11C3F, 0x11C3F, .leftToRight), (0x11C41, 0x11C45, .leftToRight), (0x11C50, 0x11C6C, .leftToRight),
        (0x11C70, 0x11C71, .leftToRight), (0x11D50, 0x11D59, .leftToRight), (0x11DA0, 0x11DA9, .leftToRight),
        (0x11EF7, 0x11EF8, .leftToRight), (0x11F43, 0x11F59, .leftToRight), (0x11FC0, 0x11FD4, .leftToRight),
        (0x11FFF, 0x11FFF, .leftToRight), (0x12400, 0x1246E, .leftToRight), (0x12470, 0x12474, .leftToRight),
        (0x12FF1, 0x12FF2, .leftToRight), (0x13430, 0x1343F, .leftToRight), (0x16130, 0x16139, .leftToRight),
        (0x16A60, 0x16A69, .leftToRight), (0x16A6E, 0x16A6F, .leftToRight), (0x16AC0, 0x16AC9, .leftToRight),
        (0x16AF5, 0x16AF5, .leftToRight), (0x16B37, 0x16B3F, .leftToRight), (0x16B44, 0x16B45, .leftToRight),
        (0x16B50, 0x16B59, .leftToRight), (0x16B5B, 0x16B61, .leftToRight), (0x16D6D, 0x16D79, .leftToRight),
        (0x16E80, 0x16E9A, .leftToRight), (0x1BC9C, 0x1BC9C, .leftToRight), (0x1BC9F, 0x1BC9F, .leftToRight),
        (0x1CCD6, 0x1CCEF, .leftToRight), (0x1CF50, 0x1CFC3, .leftToRight), (0x1D000, 0x1D0F5, .leftToRight),
        (0x1D100, 0x1D126, .leftToRight), (0x1D129, 0x1D164, .leftToRight), (0x1D16A, 0x1D16C, .leftToRight),
        (0x1D183, 0x1D184, .leftToRight), (0x1D18C, 0x1D1A9, .leftToRight), (0x1D1AE, 0x1D1E8, .leftToRight),
        (0x1D2C0, 0x1D2D3, .leftToRight), (0x1D2E0, 0x1D2F3, .leftToRight), (0x1D360, 0x1D378, .leftToRight),
        (0x1D800, 0x1D9FF, .leftToRight), (0x1DA37, 0x1DA3A, .leftToRight), (0x1DA6D, 0x1DA74, .leftToRight),
        (0x1DA76, 0x1DA83, .leftToRight), (0x1DA85, 0x1DA8B, .leftToRight), (0x1E140, 0x1E149, .leftToRight),
        (0x1E14F, 0x1E14F, .leftToRight), (0x1E2F0, 0x1E2F9, .leftToRight), (0x1E4F0, 0x1E4F9, .leftToRight),
        (0x1E5F1, 0x1E5FA, .leftToRight), (0x1E5FF, 0x1E5FF, .leftToRight), (0x1E950, 0x1E959, .rightToLeft),
        (0x1EEF0, 0x1EEF1, nil), (0x1F110, 0x1F12E, .leftToRight), (0x1F130, 0x1F169, .leftToRight),
        (0x1F170, 0x1F1AC, .leftToRight), (0x1F1E6, 0x1F202, .leftToRight), (0x1F210, 0x1F23B, .leftToRight),
        (0x1F240, 0x1F248, .leftToRight), (0x1F250, 0x1F251, .leftToRight), (0xF0000, 0xFFFFD, .leftToRight),
        (0x100000, 0x10FFFD, .leftToRight)
    ]
}
