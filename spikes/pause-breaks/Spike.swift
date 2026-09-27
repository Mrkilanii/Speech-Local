// Stage 9 spike: does a full stop at a pause split one sentence?
//
//   swiftc -O -parse-as-library Spike.swift -o /tmp/s9spike && /tmp/s9spike labelled.json results/run1.json
//
// A fresh session per call, greedy sampling, one warm-up — as the app calls
// the model. The prompt was fixed in DECLARATION.md's commit and is not tuned.

import Foundation
import FoundationModels

let instructions = """
You are a punctuation checker for dictated speech. You never answer or \
comment on the text.

Speech recognition inserts a full stop wherever the speaker pauses. You are \
given the sentence before such a full stop, and the words after it, in tags. \
Decide whether the words after the full stop continue the same sentence \
(the pause was mid-sentence) or are a sentence of their own.

Reply with exactly one word: CONTINUES or SEPARATE.
"""

struct Case: Codable { let id: Int; let before: String; let fragment: String; let label: String }
struct Result: Codable { let id: Int; let label: String; let reply: String?; let error: String?; let seconds: Double }

@main
struct Spike {
    static func main() async throws {
        let args = CommandLine.arguments
        let model = SystemLanguageModel.default
        print("availability: \(model.availability)")
        guard case .available = model.availability else { exit(1) }
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
        let options = GenerationOptions(sampling: .greedy)
        _ = try? await LanguageModelSession(instructions: instructions)
            .respond(to: "<before>It is raining.</before>\n<after>Take a coat.</after>", options: options)
        var results: [Result] = []
        for item in cases {
            let input = "<before>\(item.before)</before>\n<after>\(item.fragment)</after>"
            let start = Date()
            var reply: String?; var failure: String?
            do {
                reply = try await LanguageModelSession(instructions: instructions)
                    .respond(to: input, options: options).content
            } catch { failure = "\(error)" }
            let seconds = Date().timeIntervalSince(start)
            results.append(Result(id: item.id, label: item.label, reply: reply, error: failure, seconds: seconds))
            print(String(format: "%3d %-6@ %6.2f s %@", item.id, item.label, seconds, reply ?? "ERROR"))
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: URL(fileURLWithPath: args[2]))
    }
}
