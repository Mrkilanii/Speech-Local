import Foundation

/// What the code key writes. One key, switched in Settings or the menu bar,
/// because the same person moves between Python and Cambridge pseudocode in
/// one sitting (Trace Table has both tabs) and a hotkey per language would run
/// out of keys.
public enum CodeLanguage: String, Codable, Sendable, CaseIterable {
    case python, pseudocode, sql, typescript

    public var displayName: String {
        switch self {
        case .python: return "Python"
        case .pseudocode: return "Pseudocode (Cambridge)"
        case .sql: return "SQL (Cambridge names)"
        case .typescript: return "TypeScript"
        }
    }

    public func lines(of transcript: String) -> [PythonDictation.Line] {
        switch self {
        case .python: return PythonDictation.lines(of: transcript)
        case .pseudocode: return PseudocodeDictation.lines(of: transcript)
        // Cambridge naming — EMPLOYEE.EmployeeName — because Trace Table's SQL
        // track, where this is used, names its tables and columns that way,
        // and snake_case would not find them.
        case .sql: return SQLDictation.lines(of: transcript, naming: .cambridge)
        case .typescript: return TypeScriptDictation.lines(of: transcript)
        }
    }

    public func block(_ lines: [PythonDictation.Line], caretLine: String?) -> String {
        switch self {
        case .python: return PythonDictation.block(lines, caretLine: caretLine)
        case .pseudocode: return PseudocodeDictation.block(lines, caretLine: caretLine)
        case .sql: return SQLDictation.block(lines, caretLine: caretLine)
        case .typescript: return TypeScriptDictation.block(lines, caretLine: caretLine)
        }
    }

    public func apply(to transcript: String) -> String {
        switch self {
        case .python: return PythonDictation.apply(to: transcript)
        case .pseudocode: return PseudocodeDictation.apply(to: transcript)
        case .sql: return SQLDictation.apply(to: transcript, naming: .cambridge)
        case .typescript: return TypeScriptDictation.apply(to: transcript)
        }
    }
}
