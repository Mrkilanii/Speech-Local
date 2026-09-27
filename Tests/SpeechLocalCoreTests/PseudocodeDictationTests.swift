import Testing
@testable import SpeechLocalCore

private func pc(_ spoken: String) -> String { PseudocodeDictation.apply(to: spoken) }

/// The dictation laid out as it would be typed, from column 0.
private func typed(_ spoken: String, caretLine: String? = nil) -> String {
    PseudocodeDictation.block(PseudocodeDictation.lines(of: spoken), caretLine: caretLine)
}

@Suite struct PseudocodeDictationTests {
    // MARK: - Declarations

    @Test(arguments: [
        "declare mark integer",
        "declare mark as integer",
        "declare mark colon integer",
        "Declare mark, integer.",          // as the recognizer writes it
        "Declare Mark as an integer.",
    ])
    func declareSaysTheTypeAnyWay(spoken: String) {
        #expect(pc(spoken) == "DECLARE Mark : INTEGER")
    }

    @Test(arguments: [
        ("declare total marks real", "DECLARE TotalMarks : REAL"),
        ("declare initial char", "DECLARE Initial : CHAR"),
        ("declare found boolean", "DECLARE Found : BOOLEAN"),
        ("declare full name as string", "DECLARE FullName : STRING"),
        ("declare birthday date", "DECLARE Birthday : DATE"),
        ("constant pi equals 3.14", "CONSTANT Pi ← 3.14"),
        ("constant vat rate equals 0 point 2", "CONSTANT VatRate ← 0.2"),
    ])
    func declarationsAndConstants(spoken: String, code: String) {
        #expect(pc(spoken) == code)
    }

    @Test(arguments: [
        ("declare scores array 1 to 10 of integer", "DECLARE Scores : ARRAY[1:10] OF INTEGER"),
        ("Declare scores as array, 1 to 30 of real.", "DECLARE Scores : ARRAY[1:30] OF REAL"),
        ("declare names array open square 1 colon 5 close square of string",
         "DECLARE Names : ARRAY[1:5] OF STRING"),
        ("declare board array 1 to 3 comma 1 to 3 of char",
         "DECLARE Board : ARRAY[1:3, 1:3] OF CHAR"),
        ("declare names array of 10 strings", "DECLARE Names : ARRAY[1:10] OF STRING"),
    ])
    func arrays(spoken: String, code: String) {
        #expect(pc(spoken) == code)
    }

    // MARK: - Assignment and operators

    @Test(arguments: [
        ("total equals total plus mark", "Total ← Total + Mark"),
        ("count gets 0", "Count ← 0"),
        ("average becomes total divided by count", "Average ← Total / Count"),
        ("total is assigned 0", "Total ← 0"),
        ("remainder equals 17 mod 5", "Remainder ← 17 MOD 5"),
        ("quotient equals 17 div 5", "Quotient ← 17 DIV 5"),
        ("area equals side to the power of 2", "Area ← Side ^ 2"),
        ("name equals quote Omar close quote", #"Name ← "Omar""#),
        ("greeting equals quote hello close quote ampersand name", #"Greeting ← "hello" & Name"#),
        ("found equals false", "Found ← FALSE"),
        ("x equals negative 5", "X ← -5"),
        ("scores square brackets i equals 0", "Scores[I] ← 0"),
        ("pupil dot last name equals quote Smith", #"Pupil.LastName ← "Smith""#),
    ])
    func assignment(spoken: String, code: String) {
        #expect(pc(spoken) == code)
    }

    @Test(arguments: [
        ("if mark is equal to 100", "IF Mark = 100 THEN"),
        ("if mark equals 100", "IF Mark = 100 THEN"),              // no assignment in a condition
        ("if mark double equals 100", "IF Mark = 100 THEN"),
        ("if mark not equal to 0", "IF Mark <> 0 THEN"),
        ("if mark greater than are equal to 70", "IF Mark >= 70 THEN"),
        ("if mark less than your equal to 49", "IF Mark <= 49 THEN"),
        ("if mark greater than 0 and mark less than 100", "IF Mark > 0 AND Mark < 100 THEN"),
        ("if not found or count equal to 0", "IF NOT Found OR Count = 0 THEN"),
        ("if found is true", "IF Found = TRUE THEN"),
        ("If Mark is greater than 50, then.", "IF Mark > 50 THEN"),   // THEN never doubled
        ("if mark greater than 50 colon", "IF Mark > 50 THEN"),       // the Python colon dropped
    ])
    func conditions(spoken: String, code: String) {
        #expect(pc(spoken) == code)
    }

    // MARK: - Library routines

    @Test(arguments: [
        ("output length of name", "OUTPUT LENGTH(Name)"),
        ("last equals length name minus 1", "Last ← LENGTH(Name) - 1"),
        ("average equals round total divided by count comma 2", "Average ← ROUND(Total / Count, 2)"),
        ("half equals int total divided by 2", "Half ← INT(Total / 2)"),
        ("initial equals left name comma 1", "Initial ← LEFT(Name, 1)"),
        ("upper equals u case letter", "Upper ← UCASE(Letter)"),
        ("dice equals int random times 6 close plus 1", "Dice ← INT(RANDOM() * 6) + 1"),
        // Ordinary words when no value follows them.
        ("year equals 2024", "Year ← 2024"),
        ("birth year equals year", "BirthYear ← Year"),
    ])
    func libraryRoutines(spoken: String, code: String) {
        #expect(pc(spoken) == code)
    }

    // MARK: - Input and output

    @Test(arguments: [
        ("output quote your grade is close quote comma grade", #"OUTPUT "your grade is", Grade"#),
        ("output quote your grade is close quote grade", #"OUTPUT "your grade is", Grade"#),
        ("Output, quote, your grade is, close quote, comma, grade.", #"OUTPUT "your grade is", Grade"#),
        ("output quote total close quote and total", #"OUTPUT "total", Total"#),
        ("output name comma age", "OUTPUT Name, Age"),
        ("Output, quote, Well done!", #"OUTPUT "Well done!""#),
        ("print quote hello", #"OUTPUT "hello""#),
        ("output quote capital A", #"OUTPUT "A""#),
        ("input mark", "INPUT Mark"),
        ("mark equals input", "INPUT Mark"),
        ("Mark equals in input.", "INPUT Mark"),     // verbatim Python-mode mishearing, doctor.log
    ])
    func inputAndOutput(spoken: String, code: String) {
        #expect(pc(spoken) == code)
    }

    @Test func aPromptSaidWithInputIsAnOutputBeforeIt() {
        #expect(pc("mark equals input quote enter a mark") == "OUTPUT \"enter a mark\"\nINPUT Mark")
        #expect(pc("input quote enter a mark close quote mark") == "OUTPUT \"enter a mark\"\nINPUT Mark")
    }

    // MARK: - Blocks

    @Test func forLoopWithNext() {
        #expect(typed("for i equals 1 to 10 next line output i next line next i") == """
            FOR I ← 1 TO 10
                OUTPUT I
            NEXT I
            """)
        // A bare NEXT names its loop's variable; STEP after TO.
        #expect(typed("For count equals 10 to 0 step negative 2. Next line, output count. Next line, next.") == """
            FOR Count ← 10 TO 0 STEP -2
                OUTPUT Count
            NEXT Count
            """)
    }

    @Test func whileLoop() {
        #expect(typed("total equals 0 next line while total less than 100 next line input mark next line total equals total plus mark next line end while next line output total") == """
            Total ← 0
            WHILE Total < 100 DO
                INPUT Mark
                Total ← Total + Mark
            ENDWHILE
            OUTPUT Total
            """)
        #expect(pc("while not found do") == "WHILE NOT Found DO")
    }

    @Test func repeatUntil() {
        #expect(typed("repeat next line input password next line until password equals quote secret") == """
            REPEAT
                INPUT Password
            UNTIL Password = "secret"
            """)
    }

    @Test func functionWithReturns() {
        #expect(typed("function square taking number colon integer returns integer next line return number times number next line end function") == """
            FUNCTION Square(Number : INTEGER) RETURNS INTEGER
                RETURN Number * Number
            ENDFUNCTION
            """)
        #expect(pc("function average with total as integer comma count as integer returns real")
                == "FUNCTION Average(Total : INTEGER, Count : INTEGER) RETURNS REAL")
        #expect(pc("function is adult taking age integer returns boolean")
                == "FUNCTION IsAdult(Age : INTEGER) RETURNS BOOLEAN")
    }

    @Test func procedureAndCall() {
        #expect(typed("procedure greet taking name as string next line output quote hello close quote comma name next line end procedure next line call greet taking quote Omar") == """
            PROCEDURE Greet(Name : STRING)
                OUTPUT "hello", Name
            ENDPROCEDURE
            CALL Greet("Omar")
            """)
        #expect(pc("procedure swap taking by ref a integer and b integer")
                == "PROCEDURE Swap(BYREF A : INTEGER, B : INTEGER)")
        #expect(pc("call show menu") == "CALL ShowMenu")
    }

    @Test func theGradeProgramInOnePress() {
        // One press of the code key, punctuated the way the recognizer writes it.
        let spoken = "Declare mark, integer. Next line, output, quote, enter a mark. Next line, input mark. Next line, if mark greater than or equal to 70. Next line, output, quote, capital A. Next line, else if mark greater than or equal to 50, next line, output quote capital B. Next line, else. Next line, output quote capital F. Next line, end if. Next line, end if."
        #expect(typed(spoken) == """
            DECLARE Mark : INTEGER
            OUTPUT "enter a mark"
            INPUT Mark
            IF Mark >= 70 THEN
                OUTPUT "A"
            ELSE
                IF Mark >= 50 THEN
                    OUTPUT "B"
                ELSE
                    OUTPUT "F"
                ENDIF
            ENDIF
            """)
    }

    @Test func theGradeProgramAsACase() {
        let spoken = "declare mark integer next line input mark next line case of mark next line 70 to 100 colon output quote capital A next line 50 to 69 colon output quote capital B next line otherwise output quote capital F next line end case"
        #expect(typed(spoken) == """
            DECLARE Mark : INTEGER
            INPUT Mark
            CASE OF Mark
                70 TO 100 : OUTPUT "A"
                50 TO 69 : OUTPUT "B"
                OTHERWISE : OUTPUT "F"
            ENDCASE
            """)
    }

    @Test func nestedBlocksCloseTheirOwnOpeners() {
        #expect(typed("for i equals 1 to 5 next line if scores square brackets i greater than 50 next line count equals count plus 1 next line end if next line next i") == """
            FOR I ← 1 TO 5
                IF Scores[I] > 50 THEN
                    Count ← Count + 1
                ENDIF
            NEXT I
            """)
    }

    // MARK: - Omar's own phrasing (doctor.log, 15 Sep)

    @Test func caseOfMarkAsHeSaidIt() {
        #expect(pc("Case of Mark.") == "CASE OF Mark")
        #expect(pc("Case of Mark, colon.") == "CASE OF Mark")    // the IDE warns on that colon
        // His words, with the "next line" his dictation did not have yet.
        let lines = PseudocodeDictation.lines(of: "Case of Mark. Next line, Mark is greater than 0 And less than 50. Output, F. Next line, Mark is greater than 50. And less than 60, output C.")
        #expect(lines.map(\.text) == [
            "CASE OF Mark",
            "Mark > 0 AND Mark < 50 : OUTPUT F",     // "less than" had no subject
            "Mark > 50 AND Mark < 60 : OUTPUT C",
        ])
    }

    @Test(arguments: [
        ("70 colon output quote capital A", #"70 : OUTPUT "A""#),
        ("70 to 100 colon output quote capital A", #"70 TO 100 : OUTPUT "A""#),
        ("70 output quote capital A", #"70 : OUTPUT "A""#),
        ("quote Y close quote colon output quote yes", #""Y" : OUTPUT "yes""#),
        ("otherwise output quote capital F", #"OTHERWISE : OUTPUT "F""#),
    ])
    func caseValuesOnTheirOwn(spoken: String, code: String) {
        #expect(pc(spoken) == code)
    }

    @Test(arguments: [
        ("and if", "ENDIF"),
        ("End if.", "ENDIF"),
        ("Endif.", "ENDIF"),
        ("end-while", "ENDWHILE"),
        ("wild x less than 5", "WHILE X < 5 DO"),
        ("LF mark greater than 50", "ELSE\nIF Mark > 50 THEN"),
        ("4 I equals 1 to 10", "FOR I ← 1 TO 10"),
    ])
    func lineStartMishearings(spoken: String, code: String) {
        #expect(pc(spoken) == code)
    }

    @Test func theBlockDecidesElseAndOtherwise() {
        // "otherwise" inside an IF is ELSE; "else" inside a CASE is OTHERWISE.
        #expect(typed("if x greater than 0 next line output x next line otherwise next line output 0 next line end if") == """
            IF X > 0 THEN
                OUTPUT X
            ELSE
                OUTPUT 0
            ENDIF
            """)
        #expect(PseudocodeDictation.lines(of: "case of choice next line 1 colon call add next line else call quit")
            .map(\.text) == ["CASE OF Choice", "1 : CALL Add", "OTHERWISE : CALL Quit"])
    }

    @Test func aBodySaidOnTheHeaderLineMovesDown() {
        #expect(typed("if found then output quote yes close quote else output quote no close quote end if") == """
            IF Found THEN
                OUTPUT "yes"
            ELSE
                OUTPUT "no"
            ENDIF
            """)
        #expect(typed("for i equals 1 to 3 output i next line next") == "FOR I ← 1 TO 3\n    OUTPUT I\nNEXT I")
    }

    @Test func endAloneClosesWhatIsOpen() {
        #expect(typed("while x less than 3 next line x equals x plus 1 next line end") == """
            WHILE X < 3 DO
                X ← X + 1
            ENDWHILE
            """)
    }

    @Test(arguments: [
        ("while x less than 10 x equals x plus 1", "WHILE X < 10 DO\nX ← X + 1"),
        ("then output x", "OUTPUT X"),                       // THEN already written
        ("if mark is between 50 and 60", "IF Mark >= 50 AND Mark <= 60 THEN"),
        ("output x equals y", "OUTPUT X = Y"),              // nothing is assigned in an OUTPUT
        ("next value equals 5", "NextValue ← 5"),
        ("procedure print total taking total colon real", "PROCEDURE PrintTotal(Total : REAL)"),
        ("Procedure, calculate average, taking marks, colon, array of integer.",
         "PROCEDURE CalculateAverage(Marks : ARRAY OF INTEGER)"),
        ("if name equals quote Omar", #"IF Name = "Omar" THEN"#),
    ])
    func whatTheWordsAroundDecide(spoken: String, code: String) {
        #expect(pc(spoken) == code)
    }

    // MARK: - Files

    @Test(arguments: [
        ("open file quote data dot txt close quote for read", #"OPENFILE "data.txt" FOR READ"#),
        ("read file quote data dot txt close quote comma line", #"READFILE "data.txt", Line"#),
        ("write file quote log dot txt close quote name", #"WRITEFILE "log.txt", Name"#),
        ("close file quote data dot txt", #"CLOSEFILE "data.txt""#),
    ])
    func files(spoken: String, code: String) {
        #expect(pc(spoken) == code)
    }

    // MARK: - Placing the block at the caret

    @Test func theCaretLineSetsTheStartingIndent() {
        // Caret at the end of an IF header inside a loop.
        #expect(typed("next line output x next line end if", caretLine: "    IF X > 5 THEN")
                == "\n        OUTPUT X\n    ENDIF")
        // Caret on a CASE value: the next value lines up with it.
        #expect(typed("next line 60 colon output quote capital B",
                      caretLine: "CASE OF Mark\n    70 : OUTPUT \"A\"")
                == "\n    60 : OUTPUT \"B\"")
    }

    @Test func linesCarryTheirBreaksAndSpokenDedents() {
        #expect(PseudocodeDictation.lines(of: "output x next line step out output y") == [
            PythonDictation.Line(text: "OUTPUT X", breakBefore: false, dedent: 0),
            PythonDictation.Line(text: "OUTPUT Y", breakBefore: true, dedent: 1),
        ])
        #expect(pc("next line input mark") == "\nINPUT Mark")
    }
}
