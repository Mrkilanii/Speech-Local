import Foundation

/// A correction the user made, and the context it was made in.
public struct Correction: Codable, Sendable, Equatable {
    /// What the recognizer produced ("tip").
    public let heard: String
    /// What the user meant ("ship").
    public let intended: String
    /// Words immediately before and after, lowercased. Substitution only fires
    /// when this context recurs, so learning "tip → ship" in
    /// "tip it on monday" does not break a genuine "leave a tip".
    public let before: String?
    public let after: String?
    /// Times this correction has been confirmed. Repeated corrections are
    /// stronger evidence and are applied more readily.
    public var timesSeen: Int
    public var lastSeen: Date

    public init(heard: String, intended: String, before: String?, after: String?,
                timesSeen: Int = 1, lastSeen: Date = Date()) {
        self.heard = heard.lowercased()
        self.intended = intended
        self.before = before?.lowercased()
        self.after = after?.lowercased()
        self.timesSeen = timesSeen
        self.lastSeen = lastSeen
    }

    /// Same substitution in the same context.
    func matchesLearning(_ other: Correction) -> Bool {
        heard == other.heard && intended == other.intended
            && before == other.before && after == other.after
    }
}

/// The user's accumulated speech footprint: corrections they have made, used
/// both to bias the recognizer and to repair its output.
///
/// **This does not train Apple's speech model** — on-device fine-tuning is not
/// available. It is a personal correction layer that grows with use, which
/// produces the same practical effect: the longer it is used, the fewer times
/// the same mistake survives.
public actor LearnedCorrections {
    private var corrections: [Correction] = []
    private let storeURL: URL

    /// Times a correction must be seen before it will rewrite output. Biasing
    /// starts immediately (it is safe); substitution waits for evidence.
    public static let substitutionThreshold = 2

    public init(storeURL: URL? = nil) {
        self.storeURL = storeURL ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SpeechLocal/corrections.json")
        self.corrections = Self.load(from: self.storeURL)
    }

    // MARK: - Learning

    /// Records a correction, merging with an identical prior one.
    @discardableResult
    public func learn(_ correction: Correction) -> Correction {
        if let index = corrections.firstIndex(where: { $0.matchesLearning(correction) }) {
            corrections[index].timesSeen += 1
            corrections[index].lastSeen = Date()
            save()
            return corrections[index]
        }
        corrections.append(correction)
        save()
        return correction
    }

    /// Derives corrections from a raw transcript and the user's edited version.
    ///
    /// Two shapes are learned:
    /// * **Substitution** — same word count, one word differs ("tip" → "ship").
    /// * **Stutter deletion** — exactly one word removed, and it was a prefix of
    ///   the word that followed ("to today" → "today"). This is the one deletion
    ///   worth learning; `RulesCleanup` deliberately refuses to guess it
    ///   automatically because "go to today's meeting" looks identical.
    ///
    /// Every other edit is ignored: rewrites are the user changing their own
    /// words, not fixing a misrecognition, and learning from them poisons the store.
    public func learnFromEdit(raw: String, corrected: String) -> [Correction] {
        Self.derive(raw: raw, corrected: corrected).map { learn($0) }
    }

    /// Records what the user changed in text already inserted into their app.
    ///
    /// The diff is taken across **the insertion alone**, never the whole field.
    /// The field holds the user's own writing on both sides of it, and taking
    /// context from there learns a correction that can never fire again: "rag"
    /// fixed to "RAG" inside "my note about rag" recorded "about" as the word
    /// before it, so the next dictation of "rag" on its own did not match.
    @discardableResult
    public func learnFromInsertionEdit(
        inserted: String, snapshot: String, current: String
    ) -> [Correction] {
        guard current != snapshot,
              let edited = Self.editedInsertion(
                inserted: inserted, snapshot: snapshot, current: current)
        else { return [] }
        return Self.derive(raw: inserted, corrected: edited).map { learn($0) }
    }

    /// The insertion as it stands now, located by the user's own text on either
    /// side of it. Nil when those anchors moved, which means the user edited
    /// around our text as well and the two versions can no longer be lined up.
    static func editedInsertion(
        inserted: String, snapshot: String, current: String
    ) -> String? {
        guard let span = snapshot.range(of: inserted) else { return nil }
        let prefix = String(snapshot[..<span.lowerBound])
        let suffix = String(snapshot[span.upperBound...])
        guard current.hasPrefix(prefix), current.hasSuffix(suffix),
              current.count >= prefix.count + suffix.count else { return nil }

        let start = current.index(current.startIndex, offsetBy: prefix.count)
        let end = current.index(current.endIndex, offsetBy: -suffix.count)
        return String(current[start..<end])
    }

    /// The corrections an edit implies, before any of them are stored.
    static func derive(raw: String, corrected: String) -> [Correction] {
        let rawWords = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        let fixedWords = corrected.split(whereSeparator: \.isWhitespace).map(String.init)

        if rawWords.count == fixedWords.count + 1 {
            return deriveStutterDeletion(rawWords: rawWords, fixedWords: fixedWords)
        }
        guard rawWords.count == fixedWords.count else { return [] }

        var learned: [Correction] = []
        for (index, pair) in zip(rawWords, fixedWords).enumerated() {
            let (heard, intended) = pair
            let bareHeard = heard.trimmingCharacters(in: .punctuationCharacters)
            let bareIntended = intended.trimmingCharacters(in: .punctuationCharacters)
            guard bareHeard != bareIntended,
                  !bareHeard.isEmpty, !bareIntended.isEmpty else { continue }

            // A change of case only counts when it is not about the first
            // letter. "rag" -> "RAG" and "iphone" -> "iPhone" are facts about
            // the word; "so" -> "So" is only about where the sentence began,
            // and learning it would rewrite the word everywhere.
            if bareHeard.lowercased() == bareIntended.lowercased(),
               bareHeard.dropFirst() == bareIntended.dropFirst() { continue }

            let correction = Correction(
                heard: bareHeard,
                intended: bareIntended,
                before: index > 0 ? rawWords[index - 1]
                    .trimmingCharacters(in: .punctuationCharacters) : nil,
                after: index + 1 < rawWords.count ? rawWords[index + 1]
                    .trimmingCharacters(in: .punctuationCharacters) : nil
            )
            learned.append(correction)
        }
        return learned
    }

    /// A removed word that was a prefix of the word after it.
    private static func deriveStutterDeletion(rawWords: [String], fixedWords: [String]) -> [Correction] {
        // Find the single position where the two diverge.
        var cut: Int? = nil
        for index in 0..<rawWords.count {
            let mirrored = index < fixedWords.count ? fixedWords[index] : nil
            if mirrored?.lowercased() != rawWords[index].lowercased() { cut = index; break }
        }
        guard let cut else { return [] }

        // Everything after the removed word must line up exactly, or this is a
        // rewrite rather than a deletion.
        guard Array(rawWords[(cut + 1)...]).map({ $0.lowercased() })
            == Array(fixedWords[cut...]).map({ $0.lowercased() }) else { return [] }

        let removed = rawWords[cut].trimmingCharacters(in: .punctuationCharacters)
        guard cut + 1 < rawWords.count else { return [] }
        let following = rawWords[cut + 1].trimmingCharacters(in: .punctuationCharacters)
        guard !removed.isEmpty,
              following.lowercased().hasPrefix(removed.lowercased()),
              following.count > removed.count
        else { return [] }

        // Empty `intended` encodes "delete this word".
        return [(Correction(
            heard: removed,
            intended: "",
            before: cut > 0 ? rawWords[cut - 1]
                .trimmingCharacters(in: .punctuationCharacters) : nil,
            after: following
        ))]
    }

    // MARK: - Terms

    /// A word the user keeps correcting *into*, with every form the recognizer
    /// has produced for it.
    ///
    /// This is the unit that matters for a name. The recognizer does not repeat
    /// its mistake on a word it has never heard — it invents a new one each
    /// time. One session produced "caterion", "keturian", "caturian",
    /// "cateria", "criteria" and "criterion" for the same name, so every
    /// correction was filed separately, none was ever seen twice, and the
    /// substitution threshold was never reached however many times the user
    /// fixed it.
    ///
    /// Counting by the *target* instead makes the evidence add up.
    public struct Term: Sendable {
        public let intended: String
        public let heardForms: Set<String>
        public let timesSeen: Int
    }

    /// Targets the user has corrected into from at least
    /// `substitutionThreshold` **different** heard forms.
    ///
    /// The count of distinct forms is what separates the two cases, and it has
    /// to: a target reached repeatedly from one single form is an ordinary word
    /// swap — "tip" heard for "ship" — which must stay tied to its context, or
    /// "leave a tip for the driver" gets rewritten. A target reached from many
    /// different forms is a word the recognizer simply cannot hear, and there
    /// is no context to tie it to.
    public func terms() -> [Term] {
        var byTarget: [String: (forms: Set<String>, count: Int)] = [:]
        for correction in corrections where !correction.intended.isEmpty {
            var entry = byTarget[correction.intended] ?? (forms: [], count: 0)
            entry.forms.insert(correction.heard)
            entry.count += correction.timesSeen
            byTarget[correction.intended] = entry
        }
        return byTarget
            .filter { $0.value.forms.count >= Self.substitutionThreshold }
            .map { Term(intended: $0.key, heardForms: $0.value.forms,
                        timesSeen: $0.value.count) }
    }

    /// Shortest word a term will match by sound. Below this, too many unrelated
    /// words sit within the distance.
    static let fuzzyFloor = 5
    /// How alike two spellings must be, as a share of the longer one.
    static let fuzzyThreshold = 0.7

    /// Whether a transcript word is this term misheard again.
    ///
    /// Matched against every form the recognizer has already produced, not only
    /// against the target: the forms are the user's own record of what this word
    /// sounds like to the recognizer, and "catering" is far closer to the
    /// recorded "caterion" than to "Katurian".
    static func matches(_ word: String, term: Term) -> Bool {
        let candidate = word.lowercased()
        if term.heardForms.contains(candidate) { return true }
        guard candidate.count >= fuzzyFloor else { return false }
        return ([term.intended.lowercased()] + term.heardForms)
            .filter { $0.count >= fuzzyFloor }
            .contains { similarity(candidate, $0) >= fuzzyThreshold }
    }

    /// 1 for identical, 0 for nothing in common. Levenshtein over the longer word.
    static func similarity(_ a: String, _ b: String) -> Double {
        let longest = max(a.count, b.count)
        guard longest > 0 else { return 1 }
        return 1 - Double(distance(a, b)) / Double(longest)
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let first = Array(a), second = Array(b)
        guard !first.isEmpty else { return second.count }
        guard !second.isEmpty else { return first.count }

        var previous = Array(0...second.count)
        var current = previous
        for i in 1...first.count {
            current[0] = i
            for j in 1...second.count {
                let substitution = previous[j - 1] + (first[i - 1] == second[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            previous = current
        }
        return previous[second.count]
    }

    // MARK: - Applying

    /// Terms to bias the recognizer toward, via `AnalysisContext.contextualStrings`.
    ///
    /// Safe from the first correction: biasing only nudges the recognizer and
    /// cannot corrupt an otherwise-correct transcript.
    public func biasTerms() -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        for correction in corrections.sorted(by: { $0.timesSeen > $1.timesSeen }) {
            guard !correction.intended.isEmpty else { continue }   // deletions carry no bias term
            if seen.insert(correction.intended.lowercased()).inserted {
                terms.append(correction.intended)
            }
        }
        return terms
    }

    /// Repairs the transcript where a learned correction's context recurs.
    ///
    /// Requires the surrounding word to match, so a correction learned in one
    /// phrase does not fire everywhere the word appears.
    public func repair(_ transcript: String) -> String {
        let eligible = corrections.filter { $0.timesSeen >= Self.substitutionThreshold }
        let known = terms()
        guard !eligible.isEmpty || !known.isEmpty else { return transcript }

        var words = transcript.split(whereSeparator: \.isWhitespace).map(String.init)
        var dropped = Set<Int>()
        for index in words.indices {
            let bare = words[index].trimmingCharacters(in: .punctuationCharacters)
            guard !bare.isEmpty else { continue }
            let before = index > 0
                ? words[index - 1].trimmingCharacters(in: .punctuationCharacters).lowercased() : nil
            let after = index + 1 < words.count
                ? words[index + 1].trimmingCharacters(in: .punctuationCharacters).lowercased() : nil

            let match = eligible.first { correction in
                correction.heard == bare.lowercased()
                    && (correction.before == nil || correction.before == before)
                    && (correction.after == nil || correction.after == after)
            }
            if let match {
                if match.intended.isEmpty {
                    dropped.insert(index)          // learned stutter fragment
                } else {
                    words[index] = words[index].replacingOccurrences(of: bare, with: match.intended)
                }
                continue
            }

            // A term is a vocabulary fact rather than a contextual one, so it
            // applies wherever the word turns up and however the recognizer
            // spelled it this time.
            if let term = known.first(where: { Self.matches(bare, term: $0) }),
               bare != term.intended {
                words[index] = words[index].replacingOccurrences(of: bare, with: term.intended)
            }
        }
        return words.enumerated()
            .filter { !dropped.contains($0.offset) }
            .map(\.element)
            .joined(separator: " ")
    }

    // MARK: - Inspection

    public func all() -> [Correction] {
        corrections.sorted { $0.timesSeen > $1.timesSeen }
    }

    public func count() -> Int { corrections.count }

    public func forget(heard: String, intended: String) {
        corrections.removeAll {
            $0.heard == heard.lowercased() && $0.intended == intended
        }
        save()
    }

    // MARK: - Persistence

    /// Static and pure so it can run from `init`, where actor-isolated members
    /// are not yet reachable.
    private static func load(from url: URL) -> [Correction] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Correction].self, from: data)
        else { return [] }
        return decoded
    }

    private func save() {
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(corrections) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
