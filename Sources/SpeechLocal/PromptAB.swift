import Foundation
import FoundationModels

enum PromptAB {
    static let short = "Add punctuation and capitalization. Remove only um, uh, and repeated words. Keep all other words. Output only the text."

    static let long = """
    Add punctuation and capitalization to dictated speech. Remove only filler \
    words (um, uh, er, ah) and immediate word repetitions ("the the" becomes \
    "the"). Keep every other word exactly as spoken, including hedges (I think, \
    maybe, sort of), discourse markers (so, well, you know, actually, okay), and \
    casual forms (gonna, dont, thats). Never add words. Never remove content \
    words. Never rephrase, shorten, or summarize. Do not alter proper nouns. \
    Output only the cleaned text.
    """

    static let cases = [
        "um so the thing is uh we should ship it monday i think",
        "well you know i actually think thats gonna be a problem",
        "our counsel says the nda is unenforceable and we should countersue for damages",
        "the patch completely killed performance and murdered our latency budget",
    ]

    static func run() async {
        let opts = GenerationOptions(sampling: .greedy)
        let warm = LanguageModelSession(instructions: short)
        _ = try? await warm.respond(to: "hello", options: opts)

        for (name, prompt) in [("SHORT (20w)", short), ("LONG (85w)", long)] {
            log("\n=== \(name) ===")
            var lats: [Double] = []
            for text in cases {
                let s = LanguageModelSession(instructions: prompt)
                let t0 = Date()
                var out = ""
                do { out = try await s.respond(to: text, options: opts).content }
                catch { out = "ERROR \(error)" }
                let ms = Date().timeIntervalSince(t0) * 1000
                lats.append(ms)
                let inW = text.split(separator: " ").count
                let outW = out.split(separator: " ").count
                log(String(format: "  %5.0f ms  %2d->%2d  %@", ms, inW, outW,
                           out.isEmpty ? "<<EMPTY>>" : out))
            }
            let s = lats.sorted()
            log(String(format: "  median %.0f ms | max %.0f ms", s[s.count/2], s.last ?? 0))
        }
        log("\n=== AB COMPLETE ===")
    }
}
