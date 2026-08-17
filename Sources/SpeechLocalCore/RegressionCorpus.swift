import Foundation

/// A dictation sample and what must survive it.
public struct RegressionCase: Sendable {
    public let input: String
    /// Words that must appear in the output, case-insensitively.
    public let mustSurvive: [String]
    /// Substrings that must NOT appear (fillers, stutter fragments).
    public let mustVanish: [String]
    public let note: String

    public init(_ input: String, survives: [String] = [],
                vanishes: [String] = [], note: String) {
        self.input = input
        self.mustSurvive = survives
        self.mustVanish = vanishes
        self.note = note
    }
}

public struct RegressionFailure: Sendable, CustomStringConvertible {
    public let note: String
    public let input: String
    public let output: String
    public let problem: String

    public var description: String {
        "\(note): \(problem)\n      in:  \(input)\n      out: \(output)"
    }
}

/// Guards the one promise light-touch makes: **fix punctuation, change nothing
/// else**.
///
/// Every rule in `RulesCleanup` is a heuristic, and heuristics interact. The
/// comma policy, stray-capital fix, stutter collapse, and repeat collapse each
/// look safe alone; this corpus is what catches the case where two of them
/// combine to eat a word. It exists because the LLM this path replaced silently
/// truncated or emptied 2 of 10 utterances, and rules earn their place only by
/// being provably incapable of that.
public enum LightTouchInvariants {
    /// Words the cleanup is *allowed* to remove.
    static let removable: Set<String> = RulesCleanup.fillers

    public static let corpus: [RegressionCase] = [
        .init("um so i think we should ship it on monday",
              survives: ["think", "should", "ship", "Monday"],
              vanishes: ["um"],
              note: "filler removal keeps everything else"),

        .init("do not merge this branch until qa signs off",
              survives: ["not", "merge", "branch", "until", "signs", "off"],
              note: "NEGATION — dropping 'not' inverts the meaning"),

        .init("i never said we should cancel the contract",
              survives: ["never", "said", "cancel", "contract"],
              note: "NEGATION — 'never' must survive"),

        .init("dont ship it without the security review",
              survives: ["ship", "without", "security", "review"],
              note: "NEGATION — contraction form"),

        .init("transfer twenty five thousand dollars to account four four seven two",
              survives: ["25000", "dollars", "account", "4472"],
              note: "NUMBERS — spoken figures become digits, and a repeated digit must not collapse"),

        .init("call it version o n e not version two",
              survives: ["one", "2", "version"],
              note: "NUMBERS — spelling a number is the escape hatch back to the word"),

        .init("the meeting is at 3 30 on the 15th of march",
              // "3 30" as a phrase: checking "3" alone passes on "30".
              survives: ["3 30", "15th", "March"],
              note: "NUMBERS — numerals and ordinals"),

        .init("the comma is missing from that line",
              survives: ["comma", "missing", "line"],
              note: "PUNCTUATION — a determiner makes it a noun, not a command"),

        .init("we are out of disk space on the build machine",
              survives: ["disk space", "build", "machine"],
              note: "PUNCTUATION — collocations must not become dictation commands"),

        .init("ask omar and priya about the kubernetes migration",
              survives: ["omar", "priya", "kubernetes", "migration"],
              note: "NAMES — proper nouns must survive untouched"),

        .init("i think maybe we could possibly do it",
              survives: ["think", "maybe", "could", "possibly"],
              note: "HEDGES — these carry meaning and are not filler"),

        .init("so like you know we should actually just do it right",
              survives: ["like", "you", "know", "actually", "just", "right"],
              note: "DISCOURSE MARKERS — context-dependent, never auto-removed"),

        .init("he had had enough of that that nonsense",
              survives: ["had", "enough", "nonsense"],
              note: "legitimate doubled words survive repeat collapse"),

        .init("i was thinking, that maybe, we should do it",
              survives: ["thinking", "maybe", "should"],
              note: "sparse comma policy must not eat words"),

        .init("we need apples, oranges, and pears",
              survives: ["apples", "oranges", "pears"],
              note: "list commas preserved with all items"),

        .init("st stop the build before it deploys",
              survives: ["stop", "build", "before", "deploys"],
              vanishes: ["st "],
              note: "stutter fragment removed, real words kept"),

        .init("go to today's meeting about the roadmap",
              survives: ["to", "today", "meeting", "roadmap"],
              note: "'to today' is NOT a stutter here — must not be collapsed"),

        .init("the auth migration is way more urgent right now",
              survives: ["auth", "migration", "way", "more", "urgent", "right", "now"],
              note: "ordinary sentence passes through intact"),

        .init("call dr patel about the biopsy results before friday",
              survives: ["patel", "biopsy", "results", "before", "Friday"],
              note: "medical vocabulary is not special-cased or filtered"),
    ]

    /// Runs the corpus and returns everything that broke.
    public static func check(using engine: RulesCleanup = RulesCleanup()) -> [RegressionFailure] {
        var failures: [RegressionFailure] = []

        for testCase in corpus {
            let output = engine.apply(to: testCase.input)
            let lower = output.lowercased()

            for word in testCase.mustSurvive where !lower.contains(word.lowercased()) {
                failures.append(RegressionFailure(
                    note: testCase.note, input: testCase.input, output: output,
                    problem: "lost '\(word)'"))
            }

            for fragment in testCase.mustVanish where lower.contains(fragment.lowercased()) {
                failures.append(RegressionFailure(
                    note: testCase.note, input: testCase.input, output: output,
                    problem: "kept '\(fragment)'"))
            }

            // The universal invariant, independent of the per-case list: nothing
            // may disappear except a filler or an exact adjacent duplicate.
            if let lost = droppedContentWord(input: testCase.input, output: output) {
                failures.append(RegressionFailure(
                    note: testCase.note, input: testCase.input, output: output,
                    problem: "dropped content word '\(lost)'"))
            }

            if output.isEmpty {
                failures.append(RegressionFailure(
                    note: testCase.note, input: testCase.input, output: output,
                    problem: "EMPTY OUTPUT"))
            }
        }
        return failures
    }

    /// First input word absent from the output that had no licence to vanish.
    static func droppedContentWord(input: String, output: String) -> String? {
        // Apostrophes are stripped rather than treated as separators. Cleanup
        // restores them ("dont" -> "don't"), and splitting on non-alphanumerics
        // would turn that into "don" + "t" and report the word as lost.
        func words(_ text: String) -> [String] {
            text.lowercased()
                .replacingOccurrences(of: "'", with: "")
                .replacingOccurrences(of: "\u{2019}", with: "")
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        }

        let outWords = Set(words(output))
        let inWords = words(input)

        // The number rewrite changes a word's *form* rather than deleting it,
        // so it needs two licences here. Both directions are pinned by their
        // own tests in RulesCleanupTests; this only stops the universal
        // invariant reporting a transformation as a loss.
        let hasDigit = output.contains(where: \.isNumber)
        let numberWords = outWords.filter { SpokenNumbers.allWords.contains($0) }

        var previous: String? = nil
        for word in inWords {
            defer { previous = word }
            if removable.contains(word) { continue }
            if word == previous { continue }             // collapsed duplicate
            if outWords.contains(word) { continue }
            // "twenty five" became "25".
            if hasDigit, SpokenNumbers.allWords.contains(word) { continue }
            // "o n e" was joined back into the word it spells.
            if word.count == 1, let letter = word.first,
               numberWords.contains(where: { $0.contains(letter) }) { continue }
            // "comma" became ",". The mark is not a word, so it cannot be
            // found in the output — the per-case lists pin these instead.
            if SpokenPunctuation.isCommandWord(word) { continue }
            // A stutter fragment is licensed to vanish into the word after it.
            if let next = inWords.first(where: { $0 != word && $0.hasPrefix(word) }),
               outWords.contains(next) { continue }
            return word
        }
        return nil
    }
}

/// Machine load, for guarding benchmarks.
///
/// Exists because the same cleanup configuration measured **947 ms** on an idle
/// machine and **7 s** at load 52 during Spotlight indexing. A timing assertion
/// taken under load is fiction, and a contributor chasing that "regression"
/// would waste hours.
public enum SystemLoad {
    public static func oneMinute() -> Double {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) > 0 else { return 0 }
        return loads[0]
    }

    /// Above this, timing measurements are not trustworthy.
    public static let benchmarkCeiling: Double = 4.0

    public static var isQuietEnoughToBenchmark: Bool {
        oneMinute() < benchmarkCeiling
    }
}
