import Testing
import Foundation
@testable import SpeechLocalCore

@Test func eachLanguageRoutesToItsEngine() {
    #expect(CodeLanguage.python.apply(to: "print quote hi") == PythonDictation.apply(to: "print quote hi"))
    #expect(CodeLanguage.pseudocode.apply(to: "declare mark integer")
            == PseudocodeDictation.apply(to: "declare mark integer"))
}

@Test func settingsWithoutALanguageDecodeToPython() throws {
    let data = Data(#"{"lightTouchKey":"fn"}"#.utf8)
    #expect(try JSONDecoder().decode(Settings.self, from: data).codeLanguage == .python)
}

@Test func sqlUsesTraceTableNaming() {
    #expect(CodeLanguage.sql.apply(to: "select employee name from employee")
            == SQLDictation.apply(to: "select employee name from employee", naming: .cambridge))
    #expect(CodeLanguage.allCases.count == 4)
}
