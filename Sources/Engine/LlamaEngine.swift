import Foundation

/// What to predict: `header + stem` is fed to the model verbatim; the continuation must begin
/// with `constraint` (trailing whitespace + the partially typed word), which is how a suggestion
/// "snaps" to the word the user is in the middle of typing.
struct CompletionRequest {
    var header = ""
    var stem = ""
    var constraint = ""
    var maxTokens = 20
    /// Kept for the benchmark's command line; the beam search has its own floor.
    var minProb: Float = 0.10
    /// Not applied: the beam search scores whole phrases, on a different scale, and has its own floor.
    var minFirstProb: Float = 0.0

    /// The beam search counts words, not tokens.
    var maxWords: Int { maxTokens <= 10 ? 2 : maxTokens <= 20 ? 4 : 7 }
}

/// A tiny language model of one person's writing, trained by counting. Its "what follows what"
/// table is handed to the beam search as a bias on the next word.
struct PersonalLM {
    struct Word { var text: String; var count: Int; var unusual: Bool }
    /// Every word the user has written. `unusual` marks names and jargon the big model can't know.
    var words: [Word] = []
    /// previous word (lowercased) -> words that tend to follow it, with P(next | previous).
    var followers: [String: [(word: String, p: Float)]] = [:]
    /// previous word (lowercased) -> suggestions the user has repeatedly turned down there.
    var rejected: [String: Set<String>] = [:]
    /// How hard the user's own words pull against the model: 0 off, 1 normal.
    var strength: Float = 1
    var isEmpty: Bool { words.isEmpty && followers.isEmpty && rejected.isEmpty }
}

struct Completion {
    var text = ""  // ghost text: continuation after the constraint
    var confidence: Float = 0  // typical per-token probability of the best candidate
    var done = false
    var ms: Double = 0  // since the request was made
    var firstMs: Double = 0  // when the first usable suggestion arrived
}

enum EngineError: Error { case loadFailed(String) }

/// Undertow's face of the beam-search engine in `Ported/` (from Ghostwriter). That engine keeps
/// several candidates alive and follows the typing: when the next request is the last one plus
/// the characters just typed, the candidates that still fit are shown at once, with no decode.
final class LlamaEngine {
    private let core = CompletionEngine()
    private let lock = NSLock()
    private var latest = 0
    private var bias: TokenBias?
    private(set) var modelName = ""
    private(set) var family = "gemma"
    private(set) var isLoaded = false
    /// Diagnostics sink (nil in normal use).
    var trace: ((String) -> Void)?

    // MARK: lifecycle

    /// Blocks until the model is loaded and warm. Call off the main thread.
    func load(path: String, contextTokens: Int = 4096) throws {
        let url = URL(fileURLWithPath: path)
        var config = EngineConfig()
        config.contextSize = contextTokens
        let core = self.core
        do {
            _ = try Self.wait { try await core.load(modelAt: url, config: config) }
        } catch {
            throw EngineError.loadFailed(path)
        }
        modelName = url.lastPathComponent
        // Gemma 4 renamed the turn markers; a marker the model knows is one token.
        family = core.tokenizer?.countTokens("<|turn>") == 1 ? "gemma4" : "gemma"
        try? Self.wait { await core.warmUp() }
        isLoaded = true
    }

    func unload() {
        isLoaded = false
        cancel()
        let core = self.core
        try? Self.wait { await core.unload() }
    }

    func chatTemplate() -> String { "" }

    func setPersonalLM(_ m: PersonalLM) {
        var followers: [String: [String: Double]] = [:]
        for (prev, nexts) in m.followers {
            let turnedDown = m.rejected[prev] ?? []
            for (word, p) in nexts where !turnedDown.contains(word) { followers[prev, default: [:]][word] = Double(p) }
        }
        bias = followers.isEmpty || m.strength == 0 ? nil : TokenBias(followers: followers, strength: 1.5 * Double(m.strength))
    }

    // MARK: requests

    /// Cancels any in-flight request without starting a new one.
    func cancel() {
        lock.lock(); latest += 1; lock.unlock()
        core.cancel()
    }

    private func isCurrent(_ id: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return latest == id }

    private func beamRequest(_ r: CompletionRequest, maxWords: Int? = nil) -> BeamRequest {
        let space = r.constraint.prefix { $0.isWhitespace }
        var b = BeamRequest(
            prompt: r.header + r.stem + space, partialWord: String(r.constraint.dropFirst(space.count)),
            maxWords: maxWords ?? r.maxWords)
        b.bias = bias
        return b
    }

    /// Starts a completion; it replaces any earlier one. `onUpdate` fires off the main thread as the
    /// suggestion grows and once more with `done == true`.
    @discardableResult
    func complete(_ req: CompletionRequest, onUpdate: @escaping (Completion) -> Void) -> Int {
        lock.lock(); latest += 1; let id = latest; lock.unlock()
        let subscription = core.suggestions(for: beamRequest(req))
        Task.detached { [weak self] in
            var finished = false
            var firstMs = 0.0
            for await update in subscription.updates {
                guard let self, self.isCurrent(id) else { return }
                var c = Completion(done: update.isFinal, ms: update.milliseconds)
                if let best = update.candidates.first {
                    c.text = best.text
                    c.confidence = Float(exp(best.score))
                    if firstMs == 0 { firstMs = update.milliseconds }
                }
                c.firstMs = firstMs
                finished = finished || update.isFinal
                self.trace?("\(update.isFinal ? "final" : "part") \(Int(update.milliseconds))ms reused=\(update.reused) "
                    + update.candidates.prefix(3).map { "⟦\($0.text)⟧" }.joined(separator: " "))
                onUpdate(c)
            }
            // The stream ended with nothing to show (the search found no candidate).
            if !finished, let self, self.isCurrent(id) { onUpdate(Completion(done: true)) }
        }
        return id
    }

    func completeSync(_ req: CompletionRequest) -> Completion {
        let sem = DispatchSemaphore(value: 0)
        var result = Completion()
        complete(req) { c in if c.done { result = c; sem.signal() } }
        sem.wait()
        return result
    }

    /// Up to `count` distinct next words at this position, most likely first.
    func alternatives(_ req: CompletionRequest, count: Int, completion: @escaping ([String]) -> Void) {
        cancel()
        let request = beamRequest(req, maxWords: 1)
        let core = self.core
        Task.detached {
            let candidates = (try? await core.complete(request)) ?? []
            var seen = Set<String>()
            var words: [String] = []
            for c in candidates {
                let w = c.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !w.isEmpty, seen.insert(w.lowercased()).inserted { words.append(w) }
            }
            completion(Array(words.prefix(count)))
        }
    }

    /// Runs async engine work to completion from a plain thread.
    private static func wait<T>(_ work: @escaping () async throws -> T) throws -> T {
        let sem = DispatchSemaphore(value: 0)
        var result: Result<T, Error>?
        Task.detached {
            do { result = .success(try await work()) } catch { result = .failure(error) }
            sem.signal()
        }
        sem.wait()
        return try result!.get()
    }
}
