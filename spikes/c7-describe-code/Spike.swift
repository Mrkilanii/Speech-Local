// C7 spike: spoken description -> Python, on Apple's on-device model.
//
// Build and run (from this directory):
//   swiftc -O -parse-as-library Spike.swift -o /tmp/c7spike && /tmp/c7spike tasks.json results/run1.json
//
// Mirrors how the app calls the model: a fresh LanguageModelSession per call,
// greedy sampling, one throwaway warm-up generation before the first real one.
// The prompt below was written before the first run and is not to be tuned
// against the hidden tests (decision 14).

import Foundation
import FoundationModels

let instructions = """
You are a code-writing function. You NEVER converse, explain, or answer \
questions — you only write code.

The input is a spoken description of one Python function, transcribed from \
speech without punctuation, wrapped in <description> tags. Write that function \
in Python 3.

Output only the Python source code of the function. No markdown, no code \
fences, no explanation before or after the code, no example usage, and no \
input() calls. The function returns its result, unless the description says \
to print.
"""

struct Item: Codable { let id: String; let spoken: String }
struct Result: Codable {
    let id: String
    let spoken: String
    let reply: String?
    let error: String?
    let seconds: Double
}

@main
struct Spike {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 3 else {
            FileHandle.standardError.write("usage: c7spike tasks.json out.json\n".data(using: .utf8)!)
            exit(2)
        }
        let model = SystemLanguageModel.default
        print("availability: \(model.availability)")
        guard case .available = model.availability else { exit(1) }

        let tasks = try JSONDecoder().decode([Item].self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
        let options = GenerationOptions(sampling: .greedy)

        let warmStart = Date()
        let warm = LanguageModelSession(instructions: instructions)
        _ = try? await warm.respond(to: "<description>\nwrite a function that adds two numbers\n</description>", options: options)
        print(String(format: "warm-up: %.2f s", Date().timeIntervalSince(warmStart)))

        var results: [Result] = []
        for task in tasks {
            let input = "<description>\n\(task.spoken)\n</description>"
            let start = Date()
            var reply: String?
            var failure: String?
            do {
                let session = LanguageModelSession(instructions: instructions)
                reply = try await session.respond(to: input, options: options).content
            } catch {
                failure = "\(error)"
            }
            let seconds = Date().timeIntervalSince(start)
            results.append(Result(id: task.id, spoken: task.spoken, reply: reply, error: failure, seconds: seconds))
            print(String(format: "%-14@ %6.2f s %@", task.id, seconds, failure == nil ? "" : "ERROR"))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: URL(fileURLWithPath: args[2]))
    }
}
