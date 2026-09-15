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
