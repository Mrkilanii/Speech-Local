import Testing
@testable import SpeechLocalCore

// Left: verbatim `SpeechLocalStdin --realtime` output for a `say` recording,
// 27 Sep. Right: what the code key must write.
@Test(arguments: [
    (CodeLanguage.pseudocode, "Next time.", "NEXT"),
    (.pseudocode, "While count less than Tendo.", "WHILE Count < 10 DO"),
    (.pseudocode, "Declare total a integer", "DECLARE Total : INTEGER"),
    (.sql, "Select name commer exam from student.", "SELECT Name, Exam\nFROM STUDENT;"),
    (.sql, "Delete from student wear exam less than 50.", "DELETE FROM STUDENT\nWHERE Exam < 50;"),
    (.sql, "Group by form having average, exam greater than 60.", "GROUP BY Form\nHAVING AVG(Exam) > 60"),
    (.typescript, "Konst doubled equals 2.", "const doubled = 2;"),
    (.typescript, "if x next line log x next line Clothes block.",
     TypeScriptDictation.apply(to: "if x next line log x next line close block")),
])
func heardCodeIsRepaired(language: CodeLanguage, heard: String, code: String) {
    #expect(language.apply(to: heard) == code)
}

@Test func confusionsNeverFireOutsideTheirPlace() {
    #expect(CodeConfusions.apply("I wear a hat", for: .python) == "I wear a hat")
    #expect(CodeConfusions.apply("return constant plus 1", for: .typescript) == "return constant plus 1")
    #expect(CodeConfusions.apply("see you next time", for: .python) == "see you next time")
}
