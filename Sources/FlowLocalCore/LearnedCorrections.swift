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
            .appendingPathComponent("Library/Application Support/FlowLocal/corrections.json")
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
    /// Only single-word substitutions at matching positions are learned.
    /// Insertions, deletions, and reorderings are ignored: they are usually the
    /// user rewriting their own words, not fixing a misrecognition, and learning
    /// from them would poison the store.
    public func learnFromEdit(raw: String, corrected: String) -> [Correction] {
        let rawWords = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        let fixedWords = corrected.split(whereSeparator: \.isWhitespace).map(String.init)
        guard rawWords.count == fixedWords.count else { return [] }

        var learned: [Correction] = []
        for (index, pair) in zip(rawWords, fixedWords).enumerated() {
            let (heard, intended) = pair
            let bareHeard = heard.trimmingCharacters(in: .punctuationCharacters)
            let bareIntended = intended.trimmingCharacters(in: .punctuationCharacters)
            guard bareHeard.lowercased() != bareIntended.lowercased(),
                  !bareHeard.isEmpty, !bareIntended.isEmpty else { continue }

            let correction = Correction(
                heard: bareHeard,
                intended: bareIntended,
                before: index > 0 ? rawWords[index - 1]
                    .trimmingCharacters(in: .punctuationCharacters) : nil,
                after: index + 1 < rawWords.count ? rawWords[index + 1]
                    .trimmingCharacters(in: .punctuationCharacters) : nil
            )
            learned.append(learn(correction))
        }
        return learned
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
        guard !eligible.isEmpty else { return transcript }

        var words = transcript.split(whereSeparator: \.isWhitespace).map(String.init)
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
                words[index] = words[index].replacingOccurrences(of: bare, with: match.intended)
            }
        }
        return words.joined(separator: " ")
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
