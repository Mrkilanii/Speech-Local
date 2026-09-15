import Testing
@testable import SpeechLocalCore

// The C3 script (docs/verification.md): what the rules produce from the spoken
// script with perfect recognition. A live dictation is scored against the same
// expected code, so any difference there is the recognizer's.

let c3Presses: [(spoken: String, code: String)] = [
    ("import pandas as p d next line import numpy as n p next line import matplotlib dot pyplot as p l t",
     "import pandas as pd\nimport numpy as np\nimport matplotlib.pyplot as plt"),
    ("d f equals p d dot read csv quote sales dot csv next line d f equals d f dot drop n a next line print d f dot head next line print d f dot shape",
     "df = pd.read_csv(\"sales.csv\")\ndf = df.dropna()\nprint(df.head())\nprint(df.shape)"),
    ("total equals d f open square quote price close quote close square dot sum next line average equals n p dot mean d f open square quote price close quote close square next line print f string capital average price colon curly average close curly",
     "total = df[\"price\"].sum()\naverage = np.mean(df[\"price\"])\nprint(f\"Average price: {average}\")"),
    ("by region equals d f dot group by quote region close quote close open square quote price close quote close square dot mean next line by region dot plot kind equals quote bar next line p l t dot title quote capital average price by region next line p l t dot x label quote capital region next line p l t dot show",
     "by_region = df.groupby(\"region\")[\"price\"].mean()\nby_region.plot(kind=\"bar\")\nplt.title(\"Average price by region\")\nplt.xlabel(\"Region\")\nplt.show()"),
    ("high equals d f open square d f open square quote price close quote close square greater than 100 close square next line print len high next line for region in d f open square quote region close quote close square dot unique colon next line print region",
     "high = df[df[\"price\"] > 100]\nprint(len(high))\nfor region in df[\"region\"].unique():\n    print(region)"),
    ("def summarise taking data colon next line return data dot describe next line dedent print summarise open paren d f",
     "def summarise(data):\n    return data.describe()\nprint(summarise(df))"),
]

@Test func theC3ScriptIsDictatable() {
    for press in c3Presses {
        let got = PythonDictation.block(PythonDictation.lines(of: press.spoken), caretLine: nil)
        #expect(got == press.code, "\(press.spoken.prefix(40))…")
    }
}

// MARK: - Omar's unscripted run of the same script

@Test func theC3ScriptAsOmarActuallySaidIt() {
    // Verbatim recognizer output: one press, his own words for brackets.
    let heard = "Import pandas as PD, next line, import nump as NP, next line, Import matplotlib.pi plot as PLT, next line, DF equals PD.read underscore CSV. Quotation mark sales.csv, next line, df equals df.drop NA, next line, print df.head. Next line, printed the F dot shape, next line, total equals DF, square brackets, quotation marks, price.sum, next line, average equals np.mean, DF, square brackets, quotation marks, price. Next line, print, F quotation marks, average price colon, squiggly brackets, average, next line, buy underscore region equals df.group by. Quotation marks, region, outside of brackets, square brackets, quotation marks price, outside of brackets. mean, next line, buy underscore region.plot, kind equals quotation marks bar, next line, PLT. Quotation marks average price by region, next line, plt.xlabel, quotation marks region, next line, plt.show. Next line, high equals DF square brackets, DF square brackets, quotation marks price. Outside of the inner brackets, greater than 100. Next line, print Len high. Next line, 4 region in DF square brackets quotation marks region.unique colon. Print, next line, print region. Next line, deaf summarize data, colon, next line, return data.describe, next line, print, summarize, DF."
    let got = PythonDictation.lines(of: heard).map(\.text)
    #expect(got[1] == "import numpy as np")
    #expect(got[7] == #"total = df["price"].sum()"#)
    #expect(got[8] == #"average = np.mean(df["price"])"#)
    #expect(got[9] == #"print(f"average price: {average}")"#)
    #expect(got[10] == #"buy_region = df.groupby("region")["price"].mean()"#)
    #expect(got[15] == #"high = df[df["price"] > 100]"#)
    #expect(got[17].hasPrefix(#"for region in df["region"].unique():"#))
    #expect(got[19] == "def summarize_data():")
}
