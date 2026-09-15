import Testing
@testable import SpeechLocalCore

private func py(_ spoken: String) -> String { PythonDictation.apply(to: spoken) }

// MARK: - What the recognizer actually wrote
//
// Left column: `SpeechLocalStdin` output for a `say` recording of the spoken
// line (decision 10), copied verbatim unless marked. Each is the prose-shaped
// text the rules really receive — capitals, pause commas, full stops.

@Test func omarsOwnDictation() {
    // From doctor.log: the recognizer's output for the request that started this.
    #expect(py("car underscore 2 is equals. Input. Quotation marks. What is the color of your car?")
            == #"car_2 = input("What is the color of your car?")"#)
}

@Test(arguments: [
    ("Car underscore 2 equals input, quote, what is the color of your car?",
     #"car_2 = input("what is the color of your car?")"#),
    ("Import Pandas as PD.", "import pandas as pd"),
    ("DF equals pd.read underscore CSV quotedata.csv.", #"df = pd.read_csv("data.csv")"#),
    ("Def calculate average, open paren numbers close paren.", "def calculate_average(numbers):"),
    ("For iron range lens numbers.", "for i in range(len(numbers)):"),
    ("Else?", "else:"),
    ("Try.", "try:"),
    ("Return total divided by count.", "return total / count"),
    // Recognizer wrote "10k 100" for "ten comma one hundred"; commas restored.
    ("X equals np.lenspace 0, 10, 100.", "x = np.linspace(0, 10, 100)"),
    ("PLT.plot X, Y.", "plt.plot(x, y)"),
    ("PLT.show.", "plt.show()"),
    ("From Sklern.model selection import train test split.",
     "from sklearn.model_selection import train_test_split"),
    ("Importtorch.nn as NN.", "import torch.nn as nn"),
    ("Model equals nn.linear 10, one.", "model = nn.Linear(10, 1)"),
    ("My list equals open square one, 2, 3 close square.", "my_list = [1, 2, 3]"),
    ("While count less than 10.", "while count < 10:"),
    ("Count plus equals one.", "count += 1"),
    ("Class dog colon.", "class Dog:"),
    ("Self.name equals name.", "self.name = name"),
    ("Lambda x colon x times 2.", "lambda x: x * 2"),
    ("Df dot ilock 0", "df.iloc[0]"),
])
func recognizerOutput(spoken: String, code: String) {
    #expect(py(spoken) == code)
}

// MARK: - The language

@Test(arguments: [
    ("if x double equals 10", "if x == 10:"),
    ("elif score greater than or equal to 50", "elif score >= 50:"),
    ("if flag is not none", "if flag is not None:"),
    ("x equals none", "x = None"),
    ("pass", "pass"),
    ("return x to the power of 2", "return x ** 2"),
    ("x equals negative 5", "x = -5"),
    ("max value equals 10", "max_value = 10"),
    ("def greet taking name", "def greet(name):"),
    ("def greet", "def greet():"),
    ("def dunder init taking self", "def __init__(self):"),
    ("class data loader", "class DataLoader:"),
    ("numbers open square 1 colon 3 close square", "numbers[1:3]"),
])
func syntax(spoken: String, code: String) {
    #expect(py(spoken) == code)
}

@Test(arguments: [
    ("print quote hello close quote", #"print("hello")"#),
    ("print len numbers", "print(len(numbers))"),
    ("print len numbers close plus 1", "print(len(numbers) + 1)"),
    ("with open quote file dot txt close quote as f", #"with open("file.txt") as f:"#),
    ("if name double equals quote admin", #"if name == "admin":"#),
    ("print f string hello curly name close curly", #"print(f"hello {name}")"#),
    ("except value error as e", "except ValueError as e:"),
    ("numbers dot append new value", "numbers.append(new_value)"),
    ("f dot close", "f.close()"),
])
func callsAndStrings(spoken: String, code: String) {
    #expect(py(spoken) == code)
}

// MARK: - Libraries

@Test(arguments: [
    ("import numpy as n p", "import numpy as np"),
    ("import matplotlib dot pyplot as p l t", "import matplotlib.pyplot as plt"),
    ("df dot group by quote region close quote dot mean", #"df.groupby("region").mean()"#),
    ("model equals linear regression", "model = LinearRegression()"),
    ("model dot fit x train comma y train", "model.fit(x_train, y_train)"),
    ("sns dot histplot df comma x equals quote age", #"sns.histplot(df, x="age")"#),
    ("reader equals csv dot reader file", "reader = csv.reader(file)"),
    ("df dot shape", "df.shape"),
    ("arr equals np dot zeros 10", "arr = np.zeros(10)"),
])
func libraries(spoken: String, code: String) {
    #expect(py(spoken) == code)
}

@Test func theTableCameFromTheLibraries() {
    let names = PythonNameIndex.shared
    #expect(names.member(of: "pd", words: ["read_csv"])?.0.name == "read_csv")
    #expect(names.member(of: "nn", words: ["linear"])?.0.kind == .type)
    #expect(names.member(of: "df", words: ["shape"])?.0.kind == .attribute)
    #expect(names.module("sklern")?.name == "sklearn")
}

@Test func fuzzyMatchingNeedsAKnownOwner() {
    // "lenspace" after `np.` has one meaning; after an unknown name it is
    // somebody's identifier and must be left alone.
    #expect(py("np dot lenspace") == "np.linspace()")
    #expect(py("thing dot lenspace") == "thing.lenspace")
}

// MARK: - Omar's own voice, 15 Sep (doctor.log, code key)

@Test(arguments: [
    ("If Mark is greater than 50,", "if mark > 50:"),
    ("Greater than or equal to 0, and mark, is less than 15.", ">= 0 and mark < 15"),
    ("Case, mark, greater than or equal to 0 and mark less than 50?",
     "case mark >= 0 and mark < 50:"),
    ("Case if mark greater than are equal to 50 and mark less than 16.",
     "case _ if mark >= 50 and mark < 16:"),
    ("Case if mark greater than equal to 60 and mark less than 17.",
     "case _ if mark >= 60 and mark < 17:"),
    ("Matchmark.", "match mark:"),
    ("Colon.", ":"),
])
func realVoice(spoken: String, code: String) {
    #expect(py(spoken) == code)
}

@Test func nextLinePressesReturnInsteadOfCallingNext() {
    // Said in one press. It came out as `next(line_case, ...)`.
    let lines = PythonDictation.lines(of: "Next line. Case, mark, greater than Or equal to 50 and mark less than 60 colon, next line, Case, mark, greater than are equal to 60, and mark less than 70. Colon, next line, case mark greater than or equal to 70 and mark less than 100 colon.")
    #expect(lines.map(\.text) == [
        "case mark >= 50 and mark < 60:",
        "case mark >= 60 and mark < 70:",
        "case mark >= 70 and mark < 100:",
    ])
    #expect(lines.allSatisfy { $0.breakBefore }, "a leading next line is a Return too")
}

@Test func dedentBelongsToAFreshLineOnly() {
    let lines = PythonDictation.lines(of: "print quote f next line dedent case if mark less than 60")
    #expect(lines == [
        PythonDictation.Line(text: #"print("f")"#, breakBefore: false, dedent: 0),
        PythonDictation.Line(text: "case _ if mark < 60:", breakBefore: true, dedent: 1),
    ])
    // No Return before it: a Backspace would delete a character, so none.
    #expect(PythonDictation.lines(of: "dedent pass").first?.dedent == 0)
}

@Test func matchAndCaseAreNamesMidLine() {
    #expect(py("x equals case plus 1") == "x = case + 1")
}

// MARK: - Omar's own voice, second run: elif, else, capitals

@Test func gradeFromAMarkAsDictated() {
    // Verbatim recognizer output from doctor.log, one press of the code key.
    let lines = PythonDictation.lines(of: "If mark less than 0 or mark greater than 100 colon, next line print, quotation marks, invalid mark. Next line, LF, mark greater than equal to 70 colon, next line, print quotation marks capital A. Next line, L if more greater than are equal to 60 colon, next line, print, quotation marks, capital B. Next line, LF mark, greater than or equal to 50 colon, next time, print, quotation marks, capital C, next line, LS colon, next line, print, quotation marks, capital F.")
    #expect(lines.map(\.text) == [
        "if mark < 0 or mark > 100:",
        #"print("invalid mark")"#,
        "elif mark >= 70:",
        #"print("A")"#,
        "elif more >= 60:",          // "mark" heard as "more": not recoverable
        #"print("B")"#,
        "elif mark >= 50:",
        #"print("C")"#,
        "else:",
        #"print("F")"#,
    ])
    #expect(lines.map(\.dedent) == [0, 0, 1, 0, 1, 0, 1, 0, 1, 0],
            "elif and else step out of the body on their own")
}

@Test(arguments: [
    ("LF mark greater than 5", "elif mark > 5:"),
    ("L if x less than 2", "elif x < 2:"),
    ("else if x less than 2", "elif x < 2:"),
    ("L colon", "else:"),
    ("LS", "else:"),
    ("otherwise", "else:"),
    ("l equals 5", "l = 5"),
    ("print quote capital a", #"print("A")"#),
    ("print quote all caps game over", #"print("GAME over")"#),
])
func openingKeywordsAndCapitals(spoken: String, code: String) {
    #expect(py(spoken) == code)
}
