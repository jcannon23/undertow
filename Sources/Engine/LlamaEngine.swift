import Accelerate
import Foundation

/// What to predict: `header + stem` is fed to the model verbatim; the continuation must begin
/// with `constraint` (trailing whitespace + the partially typed word), which is how a suggestion
/// "snaps" to the word the user is in the middle of typing.
struct CompletionRequest {
    var header = ""
    var stem = ""
    var constraint = ""
    var maxTokens = 20
    /// Stop extending once the next token's probability falls below this.
    var minProb: Float = 0.10
    /// Show nothing at all if the first predicted token is below this.
    var minFirstProb: Float = 0.0
}

/// A tiny language model of one person's writing, trained by counting. It is interpolated with
/// the neural model's probabilities, weighted by how much evidence it has at this exact spot.
struct PersonalLM {
    struct Word { var text: String; var count: Int; var unusual: Bool }
    /// Every word the user has written. `unusual` marks names and jargon the big model can't know.
    var words: [Word] = []
    /// previous word (lowercased) -> words that tend to follow it, with P(next | previous).
    var followers: [String: [(word: String, p: Float)]] = [:]
    /// previous word (lowercased) -> suggestions the user has repeatedly turned down there.
    var rejected: [String: Set<String>] = [:]
    var isEmpty: Bool { words.isEmpty && followers.isEmpty && rejected.isEmpty }
}

struct Completion {
    var text = ""  // ghost text: continuation after the constraint
    var confidence: Float = 0  // probability of the first predicted token
    var done = false
    var ms: Double = 0
}

enum EngineError: Error { case loadFailed(String) }

/// Thin, single-sequence wrapper over llama.cpp tuned for keystroke-rate completion:
/// KV-cache prefix reuse, cached stem logits, prefix-constrained greedy decoding, cancellation.
final class LlamaEngine {
    private let queue = DispatchQueue(label: "undertow.llama", qos: .userInteractive)
    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var vocab: OpaquePointer?
    private var nVocab = 0
    private var nCtx = 0
    private let nBatch = 256

    private var pieces: [[UInt8]] = []  // token id -> bytes
    private var bias: [Float] = []  // 0 or -inf (banned tokens)
    /// `bias` plus chat-model tics (curly quotes, markdown, placeholders) the user is not using.
    private var plainBias: [Float] = []
    private var activeBias: [Float] = []
    private var byFirstByte: [[Int32]] = Array(repeating: [], count: 256)
    private var scratch: [Float] = []

    private var kv: [Int32] = []  // tokens currently in the KV cache
    private var savedLogits: [Float] = []  // logits after kv[0..<savedPos]
    private var savedPos = -1

    // Personal vocabulary fused into the model's scores (see `boosts`).
    private var lm = PersonalLM()
    private var lmWords: [(bytes: [UInt8], count: Float, unusual: Bool)] = []
    private var firstTokCache: [String: (Int32?, Int32?)] = [:]

    private let lock = NSLock()
    private var latest = 0
    private(set) var modelName = ""
    /// Diagnostics sink (nil in normal use).
    var trace: ((String) -> Void)?

    var isLoaded: Bool { queue.sync { ctx != nil } }

    private static let backendInit: Void = {
        llama_log_set({ _, _, _ in }, nil)
        llama_backend_init()
    }()

    // MARK: lifecycle

    func load(path: String, contextTokens: Int = 2048) throws {
        try queue.sync {
            _ = Self.backendInit
            unloadLocked()
            var mp = llama_model_default_params()
            mp.n_gpu_layers = 999
            guard let m = llama_model_load_from_file(path, mp) else { throw EngineError.loadFailed(path) }
            var cp = llama_context_default_params()
            cp.n_ctx = UInt32(contextTokens)
            cp.n_batch = UInt32(nBatch)
            cp.n_threads = 4
            cp.n_threads_batch = 4
            cp.no_perf = true
            cp.swa_full = true  // we roll the cache back constantly; a pruned SWA cache cannot
            guard let c = llama_init_from_model(m, cp) else {
                llama_model_free(m)
                throw EngineError.loadFailed(path)
            }
            model = m
            ctx = c
            vocab = llama_model_get_vocab(m)
            nCtx = Int(llama_n_ctx(c))
            nVocab = Int(llama_vocab_n_tokens(vocab))
            modelName = (path as NSString).lastPathComponent
            buildVocabTables()
            firstTokCache = [:]
            scratch = [Float](repeating: 0, count: nVocab)
            let me = Unmanaged.passUnretained(self).toOpaque()
            llama_set_abort_callback(c, { data in
                Unmanaged<LlamaEngine>.fromOpaque(data!).takeUnretainedValue().abortFlag
            }, me)
        }
    }

    func unload() { queue.sync { unloadLocked() } }

    private func unloadLocked() {
        if let ctx { llama_free(ctx) }
        if let model { llama_model_free(model) }
        ctx = nil; model = nil; vocab = nil
        kv = []; savedPos = -1; savedLogits = []
    }

    deinit { unloadLocked() }

    private func buildVocabTables() {
        pieces = []
        pieces.reserveCapacity(nVocab)
        bias = [Float](repeating: 0, count: nVocab)
        byFirstByte = Array(repeating: [], count: 256)
        var buf = [CChar](repeating: 0, count: 256)
        for t in 0..<Int32(nVocab) {
            let n = llama_token_to_piece(vocab, t, &buf, 256, 0, false)
            var bytes: [UInt8] = n > 0 ? buf[0..<Int(n)].map { UInt8(bitPattern: $0) } : []
            let banned = llama_vocab_is_control(vocab, t) || llama_vocab_is_eog(vocab, t) || bytes.isEmpty
                || bytes.first == UInt8(ascii: "<") && bytes.last == UInt8(ascii: ">") && bytes.count > 2
            if banned { bias[Int(t)] = -.infinity; bytes = [] }
            pieces.append(bytes)
            if let f = bytes.first { byFirstByte[Int(f)].append(t) }
        }
        plainBias = bias
        for t in 0..<nVocab where bias[t] == 0 {
            let p = String(decoding: pieces[t], as: UTF8.self)
            if p.contains("..") || p.unicodeScalars.contains(where: { Self.tics.contains($0) || $0.properties.isEmojiPresentation }) { plainBias[t] = -.infinity }
        }
        activeBias = bias
    }

    /// Characters instruction-tuned models love and people rarely type in prose.
    private static let tics = Set("\u{2018}\u{2019}\u{201C}\u{201D}\u{2014}\u{2013}\u{2026}*[]#_`{}<>|~^\\".unicodeScalars)

    /// Allow a tic only if the user's recent text already uses one.
    private func chooseBias(for stem: String) {
        let recent = stem.suffix(400).unicodeScalars
        activeBias = recent.contains(where: { Self.tics.contains($0) || $0.properties.isEmojiPresentation }) ? bias : plainBias
    }

    // MARK: personal language model

    func setPersonalLM(_ m: PersonalLM) {
        queue.async { [self] in
            lm = m
            lmWords = m.words.map { (Array($0.text.utf8), Float($0.count), $0.unusual) }
        }
    }

    private func firstTokens(_ w: String) -> (Int32?, Int32?) {
        if let c = firstTokCache[w] { return c }
        let r = (tokenize(" " + w, special: false, bos: false).first, tokenize(w, special: false, bos: false).first)
        firstTokCache[w] = r
        return r
    }

    /// The personal model's say at this step: `mass[t]` is probability it assigns to token t
    /// (already scaled by its weight), `lambda` the total weight taken from the neural model,
    /// `damp` tokens to hold back because the user rejected them here before.
    private struct Fusion { var mass: [Int32: Float] = [:]; var lambda: Float = 0; var damp: [Int32] = [] }

    private func fusion(_ out: [UInt8], _ req: CompletionRequest) -> Fusion {
        var f = Fusion()
        if lm.isEmpty { return f }
        func ws(_ b: UInt8) -> Bool { b == 32 || b == 10 || b == 9 }
        let text = Array(req.stem.utf8.suffix(48)) + out
        var i = text.count
        while i > 0, !ws(text[i - 1]) { i -= 1 }
        let curr = text[i...]
        var j = i
        while j > 0, ws(text[j - 1]) { j -= 1 }
        var k = j
        while k > 0, !ws(text[k - 1]) { k -= 1 }
        func key(_ b: ArraySlice<UInt8>) -> String {
            String(decoding: b, as: UTF8.self).lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" }
        }

        // 1. Finishing the current word. Weight = share of this user's words with this prefix
        //    that are names/jargon, so "Kav" -> Kavitha is near-certain while "th" stays the model's.
        if curr.count >= 2 {
            var all: Float = 0, rare: Float = 0
            var hits: [([UInt8], Float)] = []
            for w in lmWords where w.bytes.starts(with: curr) {
                all += w.count
                if w.unusual, w.bytes.count > curr.count { rare += w.count; hits.append((w.bytes, w.count)) }
            }
            if rare > 0 {
                let lambda = 0.92 * rare / (all + 1.5)
                for (bytes, c) in hits {
                    let r = bytes[curr.count...]
                    var best: Int32 = -1, bestLen = 0
                    for t in byFirstByte[Int(r.first!)] {
                        let p = pieces[Int(t)]
                        if p.count > bestLen, p.count <= r.count, r.starts(with: p) { best = t; bestLen = p.count }
                    }
                    if best >= 0 { f.mass[best, default: 0] += lambda * c / rare }
                }
                f.lambda += lambda
            }
        }

        // 2. Starting the next word, given the one before it.
        let bare = text.last.map(ws) ?? true
        let prev = bare ? key(text[k..<j]) : key(curr)
        if !prev.isEmpty {
            if let next = lm.followers[prev] {
                for (w, p) in next {
                    let (sp, br) = firstTokens(w)
                    if let t = bare ? br : sp { f.mass[t, default: 0] += 0.5 * p; f.lambda += 0.5 * p }
                }
            }
            if let no = lm.rejected[prev] {
                for w in no {
                    let (sp, br) = firstTokens(w)
                    if let t = bare ? br : sp { f.damp.append(t) }
                }
            }
        }
        f.lambda = min(f.lambda, 0.95)
        return f
    }

    // MARK: cancellation

    private var abortFlag: Bool { lock.lock(); defer { lock.unlock() }; return aborting }
    private var aborting = false
    private var running = 0

    private func isStale(_ id: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return latest != id }

    /// Cancels any in-flight request without starting a new one.
    func cancel() { lock.lock(); latest += 1; aborting = running != 0; lock.unlock() }

    // MARK: requests

    /// Starts a completion; any earlier request is cancelled. `onUpdate` fires on the engine queue
    /// at each word boundary and once more with `done == true`.
    @discardableResult
    func complete(_ req: CompletionRequest, onUpdate: @escaping (Completion) -> Void) -> Int {
        lock.lock()
        latest += 1
        let id = latest
        aborting = running != 0
        lock.unlock()
        queue.async { [self] in
            lock.lock(); aborting = false; running = id; lock.unlock()
            defer { lock.lock(); running = 0; aborting = false; lock.unlock() }
            guard ctx != nil, !isStale(id) else { return }
            generate(req, id: id, onUpdate: onUpdate)
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
        lock.lock(); latest += 1; let id = latest; aborting = running != 0; lock.unlock()
        queue.async { [self] in
            lock.lock(); aborting = false; running = id; lock.unlock()
            defer { lock.lock(); running = 0; aborting = false; lock.unlock() }
            guard ctx != nil, !isStale(id), let base = prime(req, id: id) else { return completion([]) }
            chooseBias(for: req.stem + req.constraint)
            let cons = Array(req.constraint.utf8)
            // Rank candidate first tokens from the stem logits.
            var cands: [(Int32, Float)] = []
            savedLogits.withUnsafeBufferPointer { lg in
                if cons.isEmpty {
                    for t in 0..<nVocab where activeBias[t] == 0 { cands.append((Int32(t), lg[t])) }
                } else {
                    for t in allowed(cons[...]) { cands.append((t, lg[Int(t)])) }
                }
            }
            cands.sort { $0.1 > $1.1 }
            var words: [String] = []
            var seen = Set<String>()
            for (tok, _) in cands.prefix(count * 4) where words.count < count {
                if isStale(id) { break }
                truncate(to: base)
                var out = [UInt8]()
                var rem = cons[...]
                var t = tok
                for _ in 0..<8 {
                    let p = pieces[Int(t)]
                    out += p
                    rem = rem.dropFirst(min(p.count, rem.count))
                    guard decode([t]) else { break }
                    let lg = llama_get_logits_ith(ctx, -1)!
                    guard let next = rem.isEmpty ? pickFree(lg)?.0 : pickConstrained(lg, rem)?.0 else { break }
                    if rem.isEmpty, startsWord(pieces[Int(next)]), out.count > cons.count { break }
                    t = next
                }
                guard out.count > cons.count, out.starts(with: cons) else { continue }
                let w = String(decoding: out[cons.count...], as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let key = w.lowercased()
                if !w.isEmpty, !w.contains("\u{FFFD}"), seen.insert(key).inserted { words.append(w) }
            }
            truncate(to: base)
            completion(words)
        }
    }

    // MARK: core

    private func tokenize(_ s: String, special: Bool, bos: Bool) -> [Int32] {
        if s.isEmpty && !bos { return [] }
        let utf8 = Array(s.utf8)
        var out = [Int32](repeating: 0, count: utf8.count + 8)
        let n = utf8.withUnsafeBufferPointer { p in
            p.withMemoryRebound(to: CChar.self) {
                llama_tokenize(vocab, $0.baseAddress, Int32(utf8.count), &out, Int32(out.count), bos, special)
            }
        }
        return n >= 0 ? Array(out[0..<Int(n)]) : []
    }

    private func truncate(to n: Int) {
        guard kv.count > n else { return }
        if !llama_memory_seq_rm(llama_get_memory(ctx), 0, Int32(n), -1) {
            llama_memory_clear(llama_get_memory(ctx), true)
            kv = []
            savedPos = -1
            return
        }
        kv.removeSubrange(n...)
    }

    private func decode(_ toks: [Int32]) -> Bool {
        var t = toks
        let rc = t.withUnsafeMutableBufferPointer { llama_decode(ctx, llama_batch_get_one($0.baseAddress, Int32($0.count))) }
        if rc == 0 { kv += toks; return true }
        // Aborted or failed: resync our mirror with whatever actually landed in the cache.
        let have = Int(llama_memory_seq_pos_max(llama_get_memory(ctx), 0)) + 1
        trace?("decode rc=\(rc) n=\(toks.count) kv=\(kv.count) have=\(have)")
        if have >= kv.count, have <= kv.count + toks.count { kv += toks[0..<(have - kv.count)] } else {
            llama_memory_clear(llama_get_memory(ctx), true); kv = []; savedPos = -1
        }
        return false
    }

    /// Gets the KV cache to exactly `header + stem` with `savedLogits` valid for the next token.
    /// Returns the prompt length in tokens, or nil if cancelled.
    private func prime(_ req: CompletionRequest, id: Int) -> Int? {
        let head = tokenize(req.header, special: true, bos: true)
        var body = tokenize(req.stem, special: false, bos: false)
        let budget = nCtx - req.maxTokens - 24 - head.count
        if body.count > budget {
            // Drop from the front in fixed blocks so the cached prefix survives the next keystroke.
            let block = 256
            let drop = ((body.count - budget + block - 1) / block) * block
            body.removeFirst(min(drop, body.count))
        }
        let prompt = head + body
        var common = 0
        while common < min(kv.count, prompt.count), kv[common] == prompt[common] { common += 1 }
        if common == prompt.count, savedPos == common, kv.count >= common {
            truncate(to: common)
            if kv.count == common { return common }
            common = 0  // cache was reset underneath us
        }
        if common == prompt.count { common -= 1 }
        truncate(to: common)
        if kv.count != common { common = 0 }
        var i = common
        while i < prompt.count {
            if isStale(id) { return nil }
            let end = min(i + nBatch, prompt.count)
            guard decode(Array(prompt[i..<end])) else { return nil }
            i = end
        }
        let lg = llama_get_logits_ith(ctx, -1)!
        savedLogits = Array(UnsafeBufferPointer(start: lg, count: nVocab))
        savedPos = prompt.count
        return prompt.count
    }

    private func generate(_ req: CompletionRequest, id: Int, onUpdate: (Completion) -> Void) {
        let t0 = DispatchTime.now().uptimeNanoseconds
        func elapsed() -> Double { Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 }
        guard prime(req, id: id) != nil else { trace?("prime nil id=\(id)"); return }
        chooseBias(for: req.stem + req.constraint)
        trace?("primed id=\(id) \(Int(elapsed()))ms kv=\(kv.count) cons=⟦\(req.constraint)⟧")

        let cons = Array(req.constraint.utf8)
        var rem = cons[...]
        var out = [UInt8]()
        var confidence: Float = -1
        var emitted = 0
        var free = 0
        var cut: Int? = nil  // byte length to trim to when we stop mid-word

        func ghost(_ upTo: Int) -> String {
            guard upTo > cons.count else { return "" }
            var s = String(decoding: out[cons.count..<upTo], as: UTF8.self)
            while let l = s.last, l == " " || l == "\u{FFFD}" { s.removeLast() }
            return s
        }

        var first = true
        var finished = false
        while !finished {
            if isStale(id) { return }
            let bo = fusion(out, req)
            if trace != nil, !bo.mass.isEmpty || !bo.damp.isEmpty {
                trace?("fusion out=⟦\(String(decoding: out, as: UTF8.self))⟧ lambda=\(bo.lambda) mass=\(bo.mass.map { "\(String(decoding: pieces[Int($0.key)], as: UTF8.self)):\($0.value)" }) damp=\(bo.damp.count)")
            }
            let pick: (Int32, Float)? = first
                ? savedLogits.withUnsafeBufferPointer { rem.isEmpty ? pickFree($0.baseAddress!, bo) : pickConstrained($0.baseAddress!, rem, bo) }
                : { let lg = llama_get_logits_ith(ctx, -1)!; return rem.isEmpty ? pickFree(lg, bo) : pickConstrained(lg, rem, bo) }()
            first = false
            guard let (tok, p) = pick else { cut = lastBoundary(out, floor: cons.count); break }
            let piece = pieces[Int(tok)]
            if confidence < 0 { confidence = p }
            if rem.isEmpty {
                let newWord = startsWord(piece)
                // Stop rules apply only to unconstrained tokens.
                if piece.contains(UInt8(ascii: "\n")) { if !newWord { cut = lastBoundary(out, floor: cons.count) }; break }
                if p < (out.count == cons.count ? req.minFirstProb : req.minProb) || free >= req.maxTokens {
                    if !newWord { cut = lastBoundary(out, floor: cons.count) }
                    break
                }
                if newWord, out.count > cons.count, out.count > emitted {
                    emitted = out.count
                    let g = ghost(out.count)
                    if !g.isEmpty { onUpdate(Completion(text: g, confidence: confidence, done: false, ms: elapsed())) }
                }
                free += 1
            }
            out += piece
            rem = rem.dropFirst(min(piece.count, rem.count))
            if rem.isEmpty, endsSentence(out), out.count > cons.count + 1 { finished = true }
            guard decode([tok]) else { trace?("gen decode fail id=\(id)"); return }
        }
        if isStale(id) { trace?("stale at end id=\(id)"); return }
        trace?("done id=\(id) rem=\(rem.count) out=⟦\(String(decoding: out, as: UTF8.self))⟧ cut=\(cut ?? -1)")
        let end = cut ?? out.count
        var text = rem.isEmpty ? ghost(end) : ""
        if confidence < req.minFirstProb { text = "" }
        onUpdate(Completion(text: text, confidence: max(confidence, 0), done: true, ms: elapsed()))
    }

    // MARK: sampling

    private func startsWord(_ piece: [UInt8]) -> Bool {
        guard let f = piece.first else { return true }
        // space, newline, or ASCII punctuation that opens a new token group
        return f == 32 || f == 10 || f == 9 || (f < 48 && f != 39 && f != 45) || (f > 57 && f < 65)
    }

    private func endsSentence(_ out: [UInt8]) -> Bool {
        guard let l = out.last else { return false }
        return l == UInt8(ascii: ".") || l == UInt8(ascii: "!") || l == UInt8(ascii: "?")
    }

    /// Byte offset of the end of the last complete word in `out` (never below `floor`).
    private func lastBoundary(_ out: [UInt8], floor: Int) -> Int {
        var i = out.count
        while i > floor, out[i - 1] != 32 { i -= 1 }
        return max(i, floor)
    }

    private func allowed(_ rem: ArraySlice<UInt8>) -> [Int32] {
        guard let f = rem.first else { return [] }
        return byFirstByte[Int(f)].filter { t in
            let p = pieces[Int(t)]
            return p.count <= rem.count ? rem.starts(with: p) : p.starts(with: rem)
        }
    }

    /// Greedy pick over the whole vocabulary; returns (token, probability).
    private func pickFree(_ lg: UnsafePointer<Float>, _ f: Fusion = Fusion()) -> (Int32, Float)? {
        var maxV: Float = 0
        var maxI: vDSP_Length = 0
        vDSP_vadd(lg, 1, activeBias, 1, &scratch, 1, vDSP_Length(nVocab))
        for t in f.damp { scratch[Int(t)] -= 2.5 }
        vDSP_maxvi(scratch, 1, &maxV, &maxI, vDSP_Length(nVocab))
        guard maxV.isFinite else { return nil }
        var neg = -maxV
        vDSP_vsadd(scratch, 1, &neg, &scratch, 1, vDSP_Length(nVocab))
        var n = Int32(nVocab)
        vvexpf(&scratch, scratch, &n)
        var sum: Float = 0
        vDSP_sve(scratch, 1, &sum, vDSP_Length(nVocab))
        // p(t) = (1 - lambda) * model(t) + personal(t)
        var best = Int32(maxI)
        var bestP = (1 - f.lambda) / sum + (f.mass[best] ?? 0)
        for (t, m) in f.mass where activeBias[Int(t)] == 0 || bias[Int(t)] == 0 {
            let p = (1 - f.lambda) * scratch[Int(t)] / sum + m
            if p > bestP { best = t; bestP = p }
        }
        return (best, bestP)
    }

    /// Greedy pick among tokens consistent with the bytes still owed; probability is
    /// renormalised over the consistent set (confidence *given* what was typed).
    private func pickConstrained(_ lg: UnsafePointer<Float>, _ rem: ArraySlice<UInt8>, _ f: Fusion = Fusion()) -> (Int32, Float)? {
        let cands = allowed(rem)
        guard let first = cands.first else { return nil }
        let damp = Set(f.damp)
        func logit(_ t: Int32) -> Float { lg[Int(t)] - (damp.contains(t) ? 2.5 : 0) }
        var top = logit(first)
        for t in cands where logit(t) > top { top = logit(t) }
        var sum: Float = 0
        for t in cands { sum += expf(logit(t) - top) }
        var mass: Float = 0
        for t in cands { mass += f.mass[t] ?? 0 }
        let lambda = min(f.lambda, 0.95)
        var best = first
        var bestP: Float = -1
        for t in cands {
            // personal mass that fell on tokens ruled out by the typed prefix is discarded
            let p = (1 - lambda) * expf(logit(t) - top) / sum + (f.mass[t] ?? 0)
            if p > bestP { best = t; bestP = p }
        }
        return (best, bestP / ((1 - lambda) + mass))
    }

    // MARK: introspection (bench / diagnostics)

    /// "gemma4" or "gemma": selects the turn markers used by `Prompt.header`.
    var family: String { chatTemplate().contains("<|turn>") ? "gemma4" : "gemma" }

    func chatTemplate() -> String {
        queue.sync { model.flatMap { llama_model_chat_template($0, nil) }.map { String(cString: $0) } ?? "" }
    }
}
