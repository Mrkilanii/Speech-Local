import Testing
@testable import SpeechLocalCore

private func sql(_ spoken: String) -> String { SQLDictation.apply(to: spoken) }

// MARK: - Queries, the way Trace Table's model answers are laid out
//
// Spoken forms are as a person says them; several carry the recognizer's
// prose shape (capital first word, pause commas, closing full stop) that
// decision 10 measured for Python. None is a recording of a real voice.

@Test(arguments: [
    ("select star from book", "SELECT *\nFROM book;"),
    ("Select everything from book.", "SELECT *\nFROM book;"),
    ("select all from book", "SELECT *\nFROM book;"),
    ("select title comma author from book where year greater than 2000 order by title",
     "SELECT title, author\nFROM book\nWHERE year > 2000\nORDER BY title;"),
    ("Select name, exam from student where exam is greater than or equal to 70.",
     "SELECT name, exam\nFROM student\nWHERE exam >= 70;"),
    ("select title comma price from book order by price descending",
     "SELECT title, price\nFROM book\nORDER BY price DESC;"),
    ("select title from book order by price desk limit 5",
     "SELECT title\nFROM book\nORDER BY price DESC\nLIMIT 5;"),
    ("select distinct form from student", "SELECT DISTINCT form\nFROM student;"),
    ("select student name from student", "SELECT student_name\nFROM student;"),
    // Pause commas before a keyword or an operator are prose.
    ("Select name, from student.", "SELECT name\nFROM student;"),
    ("Select star from student where age, greater than 10.",
     "SELECT *\nFROM student\nWHERE age > 10;"),
])
func queries(spoken: String, code: String) {
    #expect(sql(spoken) == code)
}

@Test(arguments: [
    ("select count star from student where exam greater than or equal to 70",
     "SELECT COUNT(*)\nFROM student\nWHERE exam >= 70;"),
    ("select sum coursework from student", "SELECT SUM(coursework)\nFROM student;"),
    ("select form comma avg exam as average exam from student group by form having avg exam greater than 60",
     "SELECT form, AVG(exam) AS average_exam\nFROM student\nGROUP BY form\nHAVING AVG(exam) > 60;"),
    ("select max price comma min price from book", "SELECT MAX(price), MIN(price)\nFROM book;"),
    ("select count distinct form from student", "SELECT COUNT(DISTINCT form)\nFROM student;"),
    ("select count of students from class", "SELECT COUNT(students)\nFROM class;"),
])
func aggregates(spoken: String, code: String) {
    #expect(sql(spoken) == code)
}

// MARK: - Conditions and strings

@Test(arguments: [
    // An unclosed string ends at the next clause, not at the end of the line.
    ("select name comma exam from student where form equals quote 10A and coursework greater than or equal to 60 order by name ascending",
     "SELECT name, exam\nFROM student\nWHERE form = '10A' AND coursework >= 60\nORDER BY name ASC;"),
    ("select title from novel where genre equals quote Fantasy or pages greater than 400",
     "SELECT title\nFROM novel\nWHERE genre = 'Fantasy' OR pages > 400;"),
    // "and" inside a value, with no comparison after it, stays in the string.
    ("select title from book where title equals quote war and peace",
     "SELECT title\nFROM book\nWHERE title = 'war and peace';"),
    ("select name from student where form not equal to quote 10A close quote",
     "SELECT name\nFROM student\nWHERE form <> '10A';"),
    ("select title from book where title like quote percent war percent",
     "SELECT title\nFROM book\nWHERE title LIKE '%war%';"),
    ("select name from student where form in quote 10A comma quote 10B",
     "SELECT name\nFROM student\nWHERE form IN ('10A', '10B');"),
    ("select name from student where exam between 50 and 70",
     "SELECT name\nFROM student\nWHERE exam BETWEEN 50 AND 70;"),
    ("select name from student where exam is null", "SELECT name\nFROM student\nWHERE exam IS NULL;"),
    ("select name from student where email is not null",
     "SELECT name\nFROM student\nWHERE email IS NOT NULL;"),
    ("select name from student where surname equals quote O'Brien",
     "SELECT name\nFROM student\nWHERE surname = 'O''Brien';"),
])
func conditions(spoken: String, code: String) {
    #expect(sql(spoken) == code)
}

// MARK: - Changing data

@Test(arguments: [
    ("insert into employee values 7 comma quote Grace Lin comma quote FIN comma 33000",
     "INSERT INTO employee\nVALUES (7, 'Grace Lin', 'FIN', 33000);"),
    ("insert into employee open bracket employee id comma employee name close bracket values 7 comma quote Grace Lin",
     "INSERT INTO employee (employee_id, employee_name)\nVALUES (7, 'Grace Lin');"),
    ("update employee set salary equals 44000 where employee id equals 3",
     "UPDATE employee\nSET salary = 44000\nWHERE employee_id = 3;"),
    ("delete from employee where salary less than 30000",
     "DELETE FROM employee\nWHERE salary < 30000;"),
    // The recognizer's thousands comma is not a second value.
    ("Update employee set salary equals 44,000 where employee ID equals 3.",
     "UPDATE employee\nSET salary = 44000\nWHERE employee_id = 3;"),
    // Pauses instead of brackets: the one after the table opens the field
    // list, and "values" closes it.
    ("Insert into employee, employee ID, employee name, values 7, quote, Grace Lin, quote FIN.",
     "INSERT INTO employee (employee_id, employee_name)\nVALUES (7, 'Grace Lin', 'FIN');"),
])
func changes(spoken: String, code: String) {
    #expect(sql(spoken) == code)
}

@Test func joinsKeepOnWithTheJoin() {
    #expect(sql("select employee dot employee name comma department dot dept name from employee inner join department on employee dot dept code equals department dot dept code order by employee dot employee name")
            == """
            SELECT employee.employee_name, department.dept_name
            FROM employee
            INNER JOIN department ON employee.dept_code = department.dept_code
            ORDER BY employee.employee_name;
            """)
}

// MARK: - Defining tables

@Test func createTableOneColumnALine() {
    #expect(sql("create table project open bracket project id integer comma project name varchar 30 comma budget real comma primary key project id close bracket")
            == """
            CREATE TABLE project (
                project_id INTEGER,
                project_name VARCHAR(30),
                budget REAL,
                PRIMARY KEY (project_id)
            );
            """)
}

@Test func createTableAsTheRecognizerWritesIt() {
    // No bracket said: the pause after the table's name opens the column
    // list, "start date date" is a name and its type, and pause commas
    // separate the columns but not a name from its type.
    #expect(sql("Create table project, project ID integer primary key, project name, varchar 30, start date date not null.")
            == """
            CREATE TABLE project (
                project_id INTEGER PRIMARY KEY,
                project_name VARCHAR(30),
                start_date DATE NOT NULL
            );
            """)
}

@Test func foreignKeysAndHeardAsIn() {
    // "int" is heard "in" (measured in Python dictation); where a type goes
    // it can only be the type.
    #expect(sql("create table employee open bracket employee id integer primary key comma age in comma dept code varchar 3 comma foreign key dept code references department dept code close bracket")
            == """
            CREATE TABLE employee (
                employee_id INTEGER PRIMARY KEY,
                age INTEGER,
                dept_code VARCHAR(3),
                FOREIGN KEY (dept_code) REFERENCES department (dept_code)
            );
            """)
}

@Test func alterTable() {
    #expect(sql("alter table employee add column email varchar 40")
            == "ALTER TABLE employee\nADD COLUMN email VARCHAR(40);")
}

// MARK: - Several statements in one press

@Test func aWholeScriptInOnePress() {
    let spoken = "create table student open bracket student id integer primary key comma name varchar 30 comma form varchar 4 comma exam integer close bracket next line insert into student values 1 comma quote Ali comma quote 10A comma 72 next line select name comma exam from student where form equals quote 10A order by exam descending"
    #expect(sql(spoken) == """
        CREATE TABLE student (
            student_id INTEGER PRIMARY KEY,
            name VARCHAR(30),
            form VARCHAR(4),
            exam INTEGER
        );
        INSERT INTO student
        VALUES (1, 'Ali', '10A', 72);
        SELECT name, exam
        FROM student
        WHERE form = '10A'
        ORDER BY exam DESC;
        """)
}

@Test func aSpokenSemicolonEndsTheStatement() {
    #expect(sql("select star from a semicolon select star from b")
            == "SELECT *\nFROM a;\nSELECT *\nFROM b;")
}

@Test func nextLineBreaksAndDoesNotDoubleAClauseBreak() {
    // "next line" before a clause keyword is the same single break; before
    // anything else it is a break of its own.
    #expect(sql("select name comma next line exam next line from student")
            == "SELECT name,\nexam\nFROM student;")
    let lines = SQLDictation.lines(of: "Next line. Select star from book.")
    #expect(lines.map(\.text) == ["SELECT *", "FROM book;"])
    #expect(lines.allSatisfy { $0.breakBefore }, "a leading next line is a line break too")
}

// MARK: - Layout at the caret

@Test func sqlBlockIndentsFromTheCaretLine() {
    // Caret inside an open column list: the next columns sit inside it.
    // A continuation, not a statement, so no `;`.
    let lines = SQLDictation.lines(of: "next line name varchar 20 comma next line form varchar 4")
    #expect(SQLDictation.block(lines, caretLine: "CREATE TABLE student (")
            == "\n    name VARCHAR(20),\n    form VARCHAR(4)")
}

// MARK: - Cambridge naming, as Trace Table's questions write it

@Test(arguments: [
    ("select employee dot employee name comma department dot dept name from employee inner join department on employee dot dept code equals department dot dept code",
     "SELECT EMPLOYEE.EmployeeName, DEPARTMENT.DeptName\nFROM EMPLOYEE\nINNER JOIN DEPARTMENT ON EMPLOYEE.DeptCode = DEPARTMENT.DeptCode;"),
    ("update employee set salary equals 44000 where employee id equals 3",
     "UPDATE EMPLOYEE\nSET Salary = 44000\nWHERE EmployeeID = 3;"),
])
func cambridgeNaming(spoken: String, code: String) {
    #expect(SQLDictation.apply(to: spoken, naming: .cambridge) == code)
}
