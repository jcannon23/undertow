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
let personalArg = opt("--personal")  // comma-separated words to boost
let nextArg = opt("--next")  // word:delta,word:delta for the first predicted word
let verbose = flag("--verbose")
let showTemplate = flag("--template")
let setPath = opt("--set")  // JSON lines: {"before": …, "truth": …, "screen": …}
let useScreen = flag("--screen")  // put each row's "screen" text in the prompt as window context
let trainPath = opt("--train")  // passages of one person's earlier writing; builds their word model
guard let modelPath = args.first else { print("usage: bench <model.gguf> [options]"); exit(2) }

let engine = LlamaEngine()
let tLoad = Date()
try engine.load(path: modelPath)
print("loaded \(engine.modelName) in \(Int(Date().timeIntervalSince(tLoad) * 1000)) ms")
if showTemplate { print(engine.chatTemplate()); engine.unload(); exit(0) }

let family = engine.family
// --personal "Kavitha:5,the:400"  (word:count; words not in a tiny common list count as unusual)
// --next "best>James:1.0"         (prev>word:probability)   --reject "should>probably"
var lm = PersonalLM()
let common: Set<String> = ["the", "they", "then", "that", "this", "keep", "kitchen", "know", "kind"]
for item in (personalArg ?? "").split(separator: ",") {
    let kv = item.split(separator: ":")
    lm.words.append(.init(text: String(kv[0]), count: Int(kv[1])!, unusual: !common.contains(String(kv[0]))))
}
for item in (nextArg ?? "").split(separator: ",") {
    let a = item.split(separator: ">"), kv = a[1].split(separator: ":")
    lm.followers[String(a[0]), default: []].append((String(kv[0]), Float(kv[1])!))
}
for item in (opt("--reject") ?? "").split(separator: ",") {
    let a = item.split(separator: ">")
    lm.rejected[String(a[0]), default: []].insert(String(a[1]))
}
if let trainPath {
    // The same counting the app does, minus the spell checker: a word seen twice that is
    // capitalised or long and rare counts as the person's own vocabulary.
    let text = try String(contentsOfFile: trainPath, encoding: .utf8)
    var uni: [String: Int] = [:], prevCount: [String: Int] = [:], pairs: [String: [String: Int]] = [:]
    for passage in text.components(separatedBy: "\n---\n") {
        var prev = ""
        for w in passage.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") }) {
            uni[String(w), default: 0] += 1
            if !prev.isEmpty { prevCount[prev, default: 0] += 1; pairs[prev, default: [:]][String(w), default: 0] += 1 }
            prev = w.lowercased()
        }
    }
    for (w, c) in uni {
        let proper = w.first!.isUppercase && uni[w.lowercased()] == nil && w.count >= 3
        lm.words.append(.init(text: w, count: c, unusual: c >= 2 && proper))
    }
    for (prev, nexts) in pairs {
        let total = Float(prevCount[prev] ?? 1)
        for (w, c) in nexts where c >= 2 { lm.followers[prev, default: []].append((w, Float(c) / total)) }
    }
    print("trained on \(uni.count) distinct words, \(lm.words.filter(\.unusual).count) personal, \(lm.followers.count) follower lists")
}
engine.setPersonalLM(lm)
if verbose { engine.trace = { print("  ·", $0) } }
var screen = ""
func request(_ before: String) -> Completion {
    guard let (stem, cons) = Prompt.split(before) else { return Completion(done: true) }
    var r = CompletionRequest()
    var ctx = Prompt.Context(app: appName)
    ctx.screen = screen
    r.header = Prompt.header(style, ctx, family: family)
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

struct Row: Decodable { var before: String; var truth: String; var screen: String? }
var rows: [Row] = passages.map { Row(before: String($0.prefix(12)), truth: String($0.dropFirst(12)), screen: nil) }
if let setPath {
    rows = try String(contentsOfFile: setPath, encoding: .utf8).split(separator: "\n").prefix(limit)
        .map { try JSONDecoder().decode(Row.self, from: Data($0.utf8)) }
}
var chars = 0, keys = 0, right = 0, wrong = 0, blank = 0
var lat: [Double] = [], first: [Double] = []
for row in rows {
    let text = row.before + row.truth
    screen = useScreen ? (row.screen ?? "") : ""
    var typed = row.before
    var sugg = ""
    var trace = typed
    while typed.count < text.count {
        if sugg.isEmpty {
            let c = request(typed)
            lat.append(c.ms)
            #if !OLD
            first.append(c.firstMs > 0 ? c.firstMs : c.ms)
            #endif
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
    chars += row.truth.count
    if verbose { print(trace, "\n") }
}
lat.sort()
let pct = { (p: Double) in lat.isEmpty ? 0 : lat[min(lat.count - 1, Int(Double(lat.count) * p))] }
print(String(format: "style=%@ minProb=%.2f minFirst=%.2f maxTok=%d", style.rawValue, minProb, minFirst, maxTokens))
print(String(format: "keystrokes saved: %.1f%%   (%d keys for %d chars)", 100 * (1 - Double(keys) / Double(chars)), keys, chars))
print(String(format: "shown-word precision: %.1f%%   (%d right, %d wrong, %d blank)", 100 * Double(right) / Double(max(1, right + wrong)), right, wrong, blank))
print(String(format: "latency ms: p50 %.0f  p90 %.0f  p99 %.0f  (%d requests)", pct(0.5), pct(0.9), pct(0.99), lat.count))
first.sort()
print(String(format: "first suggestion ms: p50 %.0f  p90 %.0f", first.isEmpty ? 0 : first[first.count / 2], first.isEmpty ? 0 : first[min(first.count - 1, first.count * 9 / 10)]))
engine.unload()
