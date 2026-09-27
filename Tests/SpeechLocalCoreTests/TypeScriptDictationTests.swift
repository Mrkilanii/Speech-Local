import Testing
@testable import SpeechLocalCore

private func ts(_ spoken: String) -> String { TypeScriptDictation.apply(to: spoken) }

// Spoken forms are as a person says them; several carry the recognizer's
// prose shape (capital first word, pause commas, closing full stop) that
// decision 10 measured for Python. None is a recording of a real voice.

// MARK: - Statements

@Test(arguments: [
    ("const user name equals quote omar", #"const userName = "omar";"#),
    ("Const user name equals, quote, Omar.", #"const userName = "Omar";"#),
    ("let count equals 0", "let count = 0;"),
    ("let count colon number equals 0", "let count: number = 0;"),
    ("const names colon string array equals empty array", "const names: string[] = [];"),
    ("count plus equals 1", "count += 1;"),
    ("count plus plus", "count++;"),
    ("const numbers equals open square 1 comma 2 comma 3 close square", "const numbers = [1, 2, 3];"),
    ("const point equals open curly x colon 1 comma y colon 2 close curly",
     "const point = { x: 1, y: 2 };"),
    ("const is valid equals true", "const isValid = true;"),
    ("const done equals not finished", "const done = !finished;"),
    ("return total divided by count", "return total / count;"),
    ("this dot name equals name", "this.name = name;"),
])
func statements(spoken: String, code: String) {
    #expect(ts(spoken) == code)
}

@Test(arguments: [
    ("console dot log quote hello world", #"console.log("hello world");"#),
    ("log quote hello", #"console.log("hello");"#),
    ("console dot log a comma b", "console.log(a, b);"),
    ("const r equals math dot floor math dot random times 10",
     "const r = Math.floor(Math.random() * 10);"),
    ("const text equals json dot stringify data", "const text = JSON.stringify(data);"),
    ("const data equals json dot parse text", "const data = JSON.parse(text);"),
    ("numbers dot push 4", "numbers.push(4);"),
    ("const last equals numbers dot pop", "const last = numbers.pop();"),
    ("const shout equals name dot to upper case", "const shout = name.toUpperCase();"),
    ("const size equals names dot length", "const size = names.length;"),
    ("const today equals new date", "const today = new Date();"),
    ("throw new error quote not found", #"throw new Error("not found");"#),
    ("greet quote omar", #"greet("omar");"#),
])
func apis(spoken: String, code: String) {
    #expect(ts(spoken) == code)
}

@Test(arguments: [
    ("const doubled equals numbers dot map n arrow n times 2",
     "const doubled = numbers.map((n) => n * 2);"),
    ("const adults equals users dot filter user arrow user dot age greater than or equal to 18",
     "const adults = users.filter((user) => user.age >= 18);"),
    ("const total equals numbers dot reduce sum comma n arrow sum plus n comma 0",
     "const total = numbers.reduce((sum, n) => sum + n, 0);"),
    ("const add equals a comma b arrow a plus b", "const add = (a, b) => a + b;"),
])
func arrows(spoken: String, code: String) {
    #expect(ts(spoken) == code)
}

@Test(arguments: [
    ("const response equals await fetch url", "const response = await fetch(url);"),
    ("const data equals await response dot json", "const data = await response.json();"),
    ("const results equals await promise dot all requests",
     "const results = await Promise.all(requests);"),
])
func asyncAndFetch(spoken: String, code: String) {
    #expect(ts(spoken) == code)
}

// MARK: - Strings

@Test(arguments: [
    ("const greeting equals template string hello dollar curly user name close curly",
     "const greeting = `hello ${userName}`;"),
    ("const path equals template string api slash users slash dollar curly id close curly",
     "const path = `api/users/${id}`;"),
    ("log template string total colon dollar sign curly a plus b close curly",
     "console.log(`total: ${a + b}`);"),
    ("const message equals quote hello comma world", #"const message = "hello, world";"#),
])
func strings(spoken: String, code: String) {
    #expect(ts(spoken) == code)
}

// MARK: - Block headers

@Test(arguments: [
    ("if count equals 0", "if (count === 0) {"),
    ("If X is greater than 5, then.", "if (x > 5) {"),
    ("if name triple equals quote admin", #"if (name === "admin") {"#),
    ("if status not equal quote done", #"if (status !== "done") {"#),
    ("if not response dot ok", "if (!response.ok) {"),
    ("if x is null", "if (x === null) {"),
    ("while count less than 10", "while (count < 10) {"),
    ("for item of items", "for (const item of items) {"),
    ("for each item in items", "for (const item of items) {"),
    ("for let i equals 0 semicolon i less than 10 semicolon i plus plus",
     "for (let i = 0; i < 10; i++) {"),
    ("function greet taking name colon string", "function greet(name: string) {"),
    ("function add taking a colon number comma b colon number returns number",
     "function add(a: number, b: number): number {"),
    ("function main", "function main() {"),
    ("async function load data returns promise of void",
     "async function loadData(): Promise<void> {"),
    ("export default function app", "export default function app() {"),
    ("class dog extends animal", "class Dog extends Animal {"),
    ("interface user profile", "interface UserProfile {"),
    ("try", "try {"),
])
func headers(spoken: String, code: String) {
    #expect(ts(spoken) == code)
}

@Test(arguments: [
    ("type id equals string or number", "type Id = string | number;"),
    ("let user colon user profile or null equals null", "let user: UserProfile | null = null;"),
])
func types(spoken: String, code: String) {
    #expect(ts(spoken) == code)
}

// MARK: - Blocks over several lines, in one press

@Test func aWholeFunctionInOnePress() {
    let spoken = "async function fetch user taking id colon number next line const response equals await fetch template string api slash users slash dollar curly id close curly next line if not response dot ok next line throw new error quote request failed next line close block next line const user equals await response dot json next line console dot log user dot name next line return user next line close block"
    #expect(ts(spoken) == """
        async function fetchUser(id: number) {
          const response = await fetch(`api/users/${id}`);
          if (!response.ok) {
            throw new Error("request failed");
          }
          const user = await response.json();
          console.log(user.name);
          return user;
        }
        """)
}

@Test func elseClosesTheBlockBeforeIt() {
    // Said with and without "close block" first: the same code.
    let expected = """
        if (score >= 50) {
          console.log("pass");
        } else {
          console.log("fail");
        }
        """
    #expect(ts("if score greater than or equal to 50 next line log quote pass next line close block next line else next line log quote fail next line close block") == expected)
    #expect(ts("if score greater than or equal to 50 next line log quote pass next line else next line log quote fail next line close block") == expected)
    // "L" is how the recognizer wrote Omar's "else" (decision 10).
    #expect(ts("if x next line log x next line LS next line log y close block")
            == "if (x) {\n  console.log(x);\n} else {\n  console.log(y);\n}")
}

@Test func callbacksCloseWithTheirBracket() {
    #expect(ts("items dot for each item arrow next line console dot log item next line close block")
            == "items.forEach((item) => {\n  console.log(item);\n});")
    #expect(ts("const greet equals name colon string arrow next line return template string hi dollar curly name close curly next line end block")
            == "const greet = (name: string) => {\n  return `hi ${name}`;\n};")
}

@Test func anUnclosedStringEndsBeforeTheNextArgument() {
    // Nobody says "close quote" (decision 10, C3). The comma ends the string
    // because an arrow follows; "hello comma world" above stays one string.
    #expect(ts("button dot add event listener quote click comma event arrow next line log event dot target next line close block")
            == "button.addEventListener(\"click\", (event) => {\n  console.log(event.target);\n});")
}

@Test func switchCasesIndentTheirBodies() {
    #expect(ts("switch day next line case 1 next line log quote monday next line break next line default next line log quote other next line close block")
            == """
            switch (day) {
              case 1:
                console.log("monday");
                break;
              default:
                console.log("other");
            }
            """)
}

@Test func objectLiteralsOverSeveralLines() {
    #expect(ts("const user equals open curly next line name colon quote omar next line age colon 17 next line close curly")
            == "const user = {\n  name: \"omar\",\n  age: 17,\n};")
}

@Test func classesAndInterfaces() {
    #expect(ts("interface user next line name colon string next line age colon number next line close block")
            == "interface User {\n  name: string;\n  age: number;\n}")
    #expect(ts("class dog extends animal next line constructor taking name colon string next line super name next line close block next line method bark next line log quote woof next line close block next line close block")
            == """
            class Dog extends Animal {
              constructor(name: string) {
                super(name);
              }
              bark() {
                console.log("woof");
              }
            }
            """)
}

@Test func methodsAreSaidWithTaking() {
    #expect(ts("class counter next line private count colon number equals 0 next line increment taking step colon number next line this dot count plus equals step next line close block next line close block")
            == """
            class Counter {
              private count: number = 0;
              increment(step: number) {
                this.count += step;
              }
            }
            """)
}

// MARK: - Layout at the caret

@Test func typeScriptBlockIndentsFromTheCaretLine() {
    // Caret at the end of a header: the body goes one level in.
    let lines = TypeScriptDictation.lines(of: "next line return x next line close block")
    #expect(TypeScriptDictation.block(lines, caretLine: "  if (x) {")
            == "\n    return x;\n  }")
    // "else" said at a caret that already follows "}": one brace, not two.
    let otherwise = TypeScriptDictation.lines(of: "else")
    #expect(TypeScriptDictation.block(otherwise, caretLine: "}") == " else {")
}
