// Simulated typist. For each passage: type it character by character, press Tab whenever the
// suggestion's next word is exactly what comes next, and report keystrokes saved, how often a
// shown word was wrong, and latency. This is the number the app is tuned against.
//
//   bench <model.gguf> [--style raw|chat] [--min-prob 0.1] [--min-first 0] [--max-tokens 20]
//         [--limit N] [--verbose] [--template] [--one "text"]
import Foundation

var args = Array(CommandLine.arguments.dropFirst())
func flag(_ n: String) -> Bool { if let i = args.firstIndex(of: n) { args.remove(at: i); return true }; return false }
func opt(_ n: String) -> String? {
    guard let i = args.firstIndex(of: n), i + 1 < args.count else { return nil }
    let v = args[i + 1]; args.removeSubrange(i...i + 1); return v
}
let style = Prompt.Style(rawValue: opt("--style") ?? "raw")!
let minProb = Float(opt("--min-prob") ?? "0.1")!
let minFirst = Float(opt("--min-first") ?? "0")!
let maxTokens = Int(opt("--max-tokens") ?? "20")!
let limit = Int(opt("--limit") ?? "999")!
let one = opt("--one")
let appName = opt("--app") ?? ""
let verbose = flag("--verbose")
let showTemplate = flag("--template")
guard let modelPath = args.first else { print("usage: bench <model.gguf> [options]"); exit(2) }

let engine = LlamaEngine()
let tLoad = Date()
try engine.load(path: modelPath)
print("loaded \(engine.modelName) in \(Int(Date().timeIntervalSince(tLoad) * 1000)) ms")
if showTemplate { print(engine.chatTemplate()); engine.unload(); exit(0) }

let family = engine.family
func request(_ before: String) -> Completion {
    guard let (stem, cons) = Prompt.split(before) else { return Completion(done: true) }
    var r = CompletionRequest()
    r.header = Prompt.header(style, Prompt.Context(app: appName), family: family)
    r.stem = stem; r.constraint = cons
    r.maxTokens = maxTokens; r.minProb = minProb; r.minFirstProb = minFirst
    return engine.completeSync(r)
}

if let one {
    for _ in 0..<2 {
        let c = request(one)
        print("[\(String(format: "%.0f", c.ms)) ms, p=\(String(format: "%.2f", c.confidence))] \(one)⟦\(c.text)⟧")
    }
    engine.unload(); exit(0)
}

let corpusPath = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("corpus.txt")
let passages = try String(contentsOf: corpusPath, encoding: .utf8)
    .components(separatedBy: "\n---\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.prefix(limit)

var chars = 0, keys = 0, right = 0, wrong = 0, blank = 0
var lat: [Double] = []
for text in passages {
    var typed = String(text.prefix(12))
    var sugg = ""
    var trace = typed
    while typed.count < text.count {
        if sugg.isEmpty {
            let c = request(typed)
            lat.append(c.ms)
            sugg = c.text
            if sugg.isEmpty { blank += 1 }
        }
        let rest = text.dropFirst(typed.count)
        let w = Prompt.nextWord(sugg)
        if !w.isEmpty, rest.hasPrefix(w) {
            keys += 1; right += 1
            typed += w; sugg.removeFirst(w.count)
            trace += "[\(w)]"
        } else {
            if !w.isEmpty { wrong += 1 }
            let ch = rest.first!
            keys += 1; typed.append(ch); trace.append(ch)
            if sugg.first == ch { sugg.removeFirst() } else { sugg = "" }
        }
    }
    chars += text.count - 12
    if verbose { print(trace, "\n") }
}
lat.sort()
let pct = { (p: Double) in lat.isEmpty ? 0 : lat[min(lat.count - 1, Int(Double(lat.count) * p))] }
print(String(format: "style=%@ minProb=%.2f minFirst=%.2f maxTok=%d", style.rawValue, minProb, minFirst, maxTokens))
print(String(format: "keystrokes saved: %.1f%%   (%d keys for %d chars)", 100 * (1 - Double(keys) / Double(chars)), keys, chars))
print(String(format: "shown-word precision: %.1f%%   (%d right, %d wrong, %d blank)", 100 * Double(right) / Double(max(1, right + wrong)), right, wrong, blank))
print(String(format: "latency ms: p50 %.0f  p90 %.0f  p99 %.0f  (%d requests)", pct(0.5), pct(0.9), pct(0.99), lat.count))
engine.unload()
