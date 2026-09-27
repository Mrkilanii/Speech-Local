import Foundation

/// What the code key writes. One key, switched in Settings or the menu bar,
/// because the same person moves between Python and Cambridge pseudocode in
/// one sitting (Trace Table has both tabs) and a hotkey per language would run
/// out of keys.
public enum CodeLanguage: String, Codable, Sendable, CaseIterable {
    case python, pseudocode

    public var displayName: String {
        switch self {
        case .python: return "Python"
        case .pseudocode: return "Pseudocode (Cambridge)"
        }
    }

    public func lines(of transcript: String) -> [PythonDictation.Line] {
        switch self {
        case .python: return PythonDictation.lines(of: transcript)
        case .pseudocode: return PseudocodeDictation.lines(of: transcript)
        }
    }

    public func block(_ lines: [PythonDictation.Line], caretLine: String?) -> String {
        switch self {
        case .python: return PythonDictation.block(lines, caretLine: caretLine)
        case .pseudocode: return PseudocodeDictation.block(lines, caretLine: caretLine)
        }
    }

    public func apply(to transcript: String) -> String {
        switch self {
        case .python: return PythonDictation.apply(to: transcript)
        case .pseudocode: return PseudocodeDictation.apply(to: transcript)
        }
    }
}
