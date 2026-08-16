import Foundation

/// Cleanup behaviour that differs per language.
///
/// Almost every rule in `RulesCleanup` encodes an assumption about English:
/// that sentences begin with a capital, that "wasnt" wants an apostrophe, that
/// "um" is noise, that a clause boundary is marked by `,`. None of that holds
/// generally. Arabic has no letter case at all, so capitalising anything is a
/// no-op at best; its comma and question mark are different code points; and
/// its fillers are entirely different words.
///
/// Running English rules over another language is not a small inaccuracy — it
/// is silently mangling the user's text. So an unsupported language gets the
/// minimal safe treatment (whitespace and duplicate-word tidying) rather than a
/// pretence of full support.
public enum Language: String, Codable, Sendable, CaseIterable {
    case english
    case arabic
    /// Transcribed and punctuated by the recognizer; only language-neutral
    /// tidying is applied.
    case other

    public init(localeIdentifier: String) {
        let code = localeIdentifier
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map(String.init)?
            .lowercased() ?? ""
        switch code {
        case "en": self = .english
        case "ar": self = .arabic
        default:   self = .other
        }
    }

    /// Whether letter case carries meaning. Arabic script is unicameral, so
    /// sentence capitalisation and the "stray capital" repair are meaningless.
    public var hasLetterCase: Bool {
        switch self {
        case .english: return true
        case .arabic:  return false
        case .other:   return true
        }
    }

    public var isRightToLeft: Bool { self == .arabic }

    /// Sounds, not words. Removed unconditionally.
    public var fillers: Set<String> {
        switch self {
        case .english:
            return ["um", "uh", "erm", "uhh", "umm", "hmm", "mm", "mmm"]
        case .arabic:
            // Hesitation sounds. Note what is absent: "يعني" (yaʿni) and "طيب"
            // are extremely common but carry real meaning, exactly like the
            // English "like" and "so" that are deliberately excluded.
            return ["اه", "اهه", "امم", "مم", "ايه", "اا", "ههه"]
        case .other:
            return []
        }
    }

    /// Sentence-terminating punctuation for this script.
    public var terminators: Set<Character> {
        switch self {
        case .english, .other: return [".", "!", "?"]
        // U+061F ARABIC QUESTION MARK, alongside the Latin forms that Apple's
        // recognizer also emits.
        case .arabic:          return [".", "!", "?", "؟"]
        }
    }

    /// The comma this language actually uses.
    public var comma: Character {
        switch self {
        case .english, .other: return ","
        case .arabic:          return "،"   // U+060C ARABIC COMMA
        }
    }

    public var defaultTerminator: Character {
        switch self {
        case .english, .other: return "."
        case .arabic:          return "."
        }
    }

    /// Words that legitimately follow a comma, used to tell a grammatical comma
    /// from one the recognizer inserted at a pause.
    public var clauseMarkers: Set<String> {
        switch self {
        case .english:
            return ["and", "but", "or", "so", "because", "which", "who",
                    "although", "though", "however", "then", "if", "unless",
                    "while", "whereas", "please", "too", "right", "okay"]
        case .arabic:
            return ["و", "لكن", "أو", "او", "لأن", "لان", "التي", "الذي",
                    "لكي", "حتى", "إذا", "اذا", "ثم", "بينما", "أما", "اما"]
        case .other:
            return []
        }
    }

    /// Whether contraction repair applies. Only English has the apostrophe
    /// problem this solves.
    public var hasContractions: Bool { self == .english }

    /// Whether day and month names should be capitalised. English does; Arabic
    /// has no case, and other languages vary (German capitalises all nouns,
    /// French does not capitalise months at all), so it is not attempted.
    public var capitalisesDayNames: Bool { self == .english }
}
