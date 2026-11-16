// Adapted from Ghostwriter (https://github.com/mshll/ghostwriter), GPL-3.0. Changed for Undertow, 2026-11.
import Foundation

struct ScoredPath {
    var logprob = 0.0
    var ends: [Int] = []
    var logprobs: [Double] = []

    func appending(end: Int, logprob tokenLogprob: Double) -> ScoredPath {
        ScoredPath(logprob: logprob + tokenLogprob, ends: ends + [end], logprobs: logprobs + [tokenLogprob])
    }
}

struct Beam {
    var sequence = Session.baseSequence
    /// Index of the parent in the list being expanded; -1 once the beam owns `sequence`.
    var parent = -1
    var tokens: [Int32] = []
    var bytes: [UInt8] = []
    var path = ScoredPath()
    var probabilitySum = 0.0
    var probabilityCount = 0
    var pendingSentenceEnd = false
    /// Probability of the beam's first token, among the tokens that fit what was typed.
    var firstProbability = 0.0

    var meanProbability: Double { probabilityCount > 0 ? probabilitySum / Double(probabilityCount) : 0 }

    func extended(with token: Int32, piece: ArraySlice<UInt8>, logprob: Double, parent: Int) -> Beam {
        var child = self
        child.sequence = -1
        child.parent = parent
        child.tokens.append(token)
        child.bytes += piece
        child.path = path.appending(end: child.bytes.count, logprob: logprob)
        return child
    }

    func remaining(_ required: [UInt8]) -> ArraySlice<UInt8> {
        bytes.count < required.count ? required[bytes.count...] : []
    }

    func follows(_ required: [UInt8]) -> Bool {
        bytes.count >= required.count ? bytes.starts(with: required) : required.starts(with: bytes)
    }
}

struct FinishedText {
    var bytes: [UInt8]
    var path: ScoredPath
    var parked: Int?
    var first = 0.0
}

struct ParkedBeam {
    var id: Int
    var beam: Beam
    var slot: Int
}

final class BeamSearch {
    static let parkLimit = 6

    private let session: Session
    private(set) var request: BeamRequest
    let prompt: PreparedPrompt
    let rootVersion: Int
    private let abort: AbortSignal
    private let parks: Bool
    private let inline: Bool
    private let width: Int
    private let topK: Int
    private let maxWords: Double
    private let stopStrings: [String]
    private let lineStopStrings: [String]
    private(set) var required: [UInt8]
    private var anchor = 0
    private var echoSource: String
    private var echoGrams: Set<String>
    private var spaceBeforeCandidates: Bool
    private(set) var steps = 0
    private var pending: [Beam] = []
    private var finished: [FinishedText] = []
    private var parked: [ParkedBeam] = []
    private var nextParkedID = 0
    private var parkRequested = false
    private var expanding: Set<Int32> = []

    private static let constrainedListLimit = 4096
    private static let draftMinimumWords = 8.0
    private static let constrainedScanSize = 512
    private static let newline: UInt8 = 0x0A
    private static let space: UInt8 = 0x20

    init(session: Session, request: BeamRequest, prompt: PreparedPrompt, abort: AbortSignal, parks: Bool) {
        self.session = session
        self.request = request
        self.prompt = prompt
        self.abort = abort
        rootVersion = session.rootVersion
        inline = request.mode == .inline
        self.parks = parks && inline
        let beams = min(max(request.beams, 1), session.maxBeams)
        let midLineBeams = request.textAfter.isEmpty ? beams : min(beams, max(request.tuning.midLineBeams ?? beams, 1))
        width = inline ? midLineBeams : min(beams, 2)
        topK = max(request.topK, 1)
        maxWords = Double(max(request.maxWords, 1))
        stopStrings = request.stopStrings.filter { !$0.isEmpty && !$0.hasPrefix("\n") }
        lineStopStrings = request.stopStrings.filter { $0.hasPrefix("\n") }
        required = prompt.required
        spaceBeforeCandidates = TextRules.endsWithSpaceAfterText(prompt.tail + TextRules.decodeComplete(prompt.required))
        echoSource = prompt.context
        echoGrams = TextRules.wordGrams(TextRules.words(prompt.context), length: TextRules.echoWords)
    }

    private func stopIndex(in text: String) -> String.Index? {
        let anywhere = stopStrings.compactMap { text.range(of: $0)?.lowerBound }.min()
        guard !lineStopStrings.isEmpty else { return anywhere }
        for index in text.indices where text[index] == "\n" {
            if let anywhere, index >= anywhere { break }
            let rest = text[index...]
            if lineStopStrings.contains(where: { rest.hasPrefix($0) }) { return index }
        }
        return anywhere
    }

    private var context: any DecodeContext { session.context }
    private var vocabulary: LlamaVocabulary { session.vocabulary }

    private var isNarrowed: Bool {
        guard inline, let narrowAfter = request.tuning.narrowAfterSteps else { return false }
        return steps >= narrowAfter
    }

    private var maxDepth: Int { (inline ? request.maxWords * 3 + 6 : 120) + required.count }

    var isDone: Bool {
        guard !pending.isEmpty else { return true }
        guard let margin = request.tuning.earlyStopMargin, let bestFinished = finished.map({ score($0.path) }).max(),
              let bestLive = pending.map({ score($0.path) }).max() else { return false }
        return bestFinished >= bestLive + margin
    }

    var stableText: String? {
        guard var common = pending.first?.bytes else { return nil }
        for beam in pending.dropFirst() {
            common = Array(common.prefix(zip(common, beam.bytes).prefix { $0 == $1 }.count))
        }
        guard common.count > required.count, common.starts(with: required) else { return nil }
        let text = TextRules.trimmingTrailingWhitespace(TextRules.trimmingPartialWord(TextRules.decodeComplete(common[required.count...])))
        return TextRules.hasWordCharacter(text) ? text : nil
    }

    func start() throws {
        _ = session.workRow.update(fromContentsOf: UnsafeBufferPointer(session.promptLogits))
        guard let row = session.workRow.baseAddress else { throw InferenceError.decodeFailed(-1) }
        let root = Beam()
        var children: [Beam] = []
        expand(root, parent: 0, row: row, biased: false, slot: nil, into: &children)
        try select(children, parents: [root])
    }

    var batchRoom: Int { context.batchCapacity - pending.count }

    var sequencesNeeded: Int { max(0, width - pending.count) }

    @discardableResult
    func step(extra: [DecodeEntry] = []) throws -> Int {
        if abort.isCancelled || Task.isCancelled { throw CancellationError() }
        let decoding = pending
        try context.decode(decoding.map {
            DecodeEntry(token: $0.tokens.last ?? 0, position: prompt.tokens.count + $0.tokens.count - 1, sequence: $0.sequence, wantsLogits: true)
        } + extra)
        steps += 1
        expanding = Set(decoding.map(\.sequence))
        defer { expanding = [] }
        var children: [Beam] = []
        for (index, beam) in decoding.enumerated() {
            guard let row = context.logits(at: index) else { throw InferenceError.decodeFailed(-1) }
            if beam.tokens.count >= maxDepth {
                finishAtLimit(beam, row: row)
            } else {
                expand(beam, parent: index, row: row, biased: false, slot: nil, into: &children)
            }
        }
        try select(children, parents: decoding)
        return decoding.count
    }

    func follow(_ request: BeamRequest, appended: [UInt8], anchor: Int) throws -> Bool {
        self.request = request
        required += appended
        spaceBeforeCandidates = TextRules.endsWithSpaceAfterText(prompt.tail + TextRules.decodeComplete(required))
        if anchor != self.anchor {
            self.anchor = anchor
            let typed = TextRules.decodeComplete(required.prefix(anchor))
            echoSource = String((prompt.context + typed).suffix(Session.echoWindow))
            echoGrams = TextRules.wordGrams(TextRules.words(echoSource), length: TextRules.echoWords)
        }
        finished.removeAll { text(of: $0) == nil }
        var carried: [Beam] = []
        for beam in pending {
            if beam.follows(required), !doublesSpace(text(of: beam)) {
                carried.append(beam)
            } else {
                session.releaseSequence(beam.sequence)
            }
        }
        pending = carried
        var revived: [ParkedBeam] = []
        let previouslyParked = parked
        parked = []
        for entry in previouslyParked {
            if !entry.beam.follows(required) || doublesSpace(text(of: entry.beam)) {
                session.releaseSequence(entry.beam.sequence)
                session.releaseRow(entry.slot)
            } else if entry.beam.remaining(required).isEmpty, TextRules.wordUnits(text(of: entry.beam)) >= maxWords {
                parked.append(entry)
            } else {
                revived.append(entry)
            }
        }
        let revivedIDs = Set(revived.map(\.id))
        finished.removeAll { $0.parked.map(revivedIDs.contains) ?? false }
        var children: [Beam] = []
        expanding = Set(revived.map(\.beam.sequence))
        defer { expanding = [] }
        for (index, entry) in revived.enumerated() {
            expand(entry.beam, parent: index, row: session.row(entry.slot), biased: true, slot: entry.slot, into: &children)
            if !parked.contains(where: { $0.slot == entry.slot }) { session.releaseRow(entry.slot) }
        }
        try select(carried + children, parents: revived.map(\.beam))
        return !pending.isEmpty || !finished.isEmpty
    }

    func release() {
        for beam in pending { session.releaseSequence(beam.sequence) }
        for entry in parked {
            session.releaseSequence(entry.beam.sequence)
            session.releaseRow(entry.slot)
        }
        pending = []
        parked = []
    }

    func ranked() -> [Candidate] {
        let limit = min(max(request.tuning.maxCandidates, 1), session.maxBeams - 1)
        let scored = finished.compactMap { entry in text(of: entry).map { ($0, score(entry.path), entry.first) } }.sorted { $0.1 > $1.1 }
        var seen = Set<String>()
        var result: [Candidate] = []
        for (text, score, first) in scored where seen.insert(text).inserted {
            var candidate = Candidate(text: text, score: score)
            candidate.firstProbability = first
            result.append(candidate)
            if result.count == limit { break }
        }
        return result
    }

    func provisional() -> [Candidate] {
        var scored = finished.compactMap { entry in text(of: entry).map { ($0, score(entry.path), entry.first) } }
        for beam in pending {
            let text = TextRules.trimmingTrailingWhitespace(TextRules.trimmingPartialWord(text(of: beam)))
            if TextRules.hasWordCharacter(text) { scored.append((text, score(beam.path), beam.firstProbability)) }
        }
        let limit = min(max(request.tuning.maxCandidates, 1), session.maxBeams - 1)
        var seen = Set<String>()
        return scored.sorted { $0.1 > $1.1 }.filter { seen.insert($0.0).inserted }.prefix(limit).map {
            var candidate = Candidate(text: $0.0, score: $0.1)
            candidate.firstProbability = $0.2
            return candidate
        }
    }

    // MARK: Selection

    private func select(_ candidates: [Beam], parents: [Beam]) throws {
        let ranked = candidates.sorted { score($0.path) > score($1.path) }
        var next = Array(ranked.prefix(isNarrowed ? 1 : width))
        let parkedSequences = Set(parked.map(\.beam.sequence))
        var claimed = Set<Int32>()
        var copies: [Int] = []
        for index in next.indices where next[index].parent >= 0 {
            let source = parents[next[index].parent].sequence
            if source != Session.baseSequence, !parkedSequences.contains(source), claimed.insert(source).inserted {
                next[index].sequence = source
            } else {
                copies.append(index)
            }
        }
        for parent in parents where parent.sequence != Session.baseSequence && !claimed.contains(parent.sequence)
            && !parkedSequences.contains(parent.sequence)
        {
            session.releaseSequence(parent.sequence)
        }
        let keptOwners = Set(next.filter { $0.parent < 0 }.map(\.sequence))
        for beam in candidates where beam.parent < 0 && !keptOwners.contains(beam.sequence) {
            session.releaseSequence(beam.sequence)
        }
        for (done, index) in copies.enumerated() {
            guard let sequence = session.allocateSequence() else {
                // Parents are released above, so pending lists only what the kept beams hold.
                let missing = Set(copies[done...])
                pending = next.indices.filter { !missing.contains($0) }.map { next[$0] }
                throw InferenceError.decodeFailed(-1)
            }
            context.copySequence(parents[next[index].parent].sequence, to: sequence)
            next[index].sequence = sequence
        }
        for index in next.indices { next[index].parent = -1 }
        pending = next
    }

    // MARK: Expansion

    private func expand(
        _ beam: Beam, parent: Int, row: UnsafeMutablePointer<Float>, biased: Bool, slot: Int?, into children: inout [Beam]
    ) {
        if !biased { applyBias(to: row, for: beam) }
        let logits = UnsafeBufferPointer(start: row, count: vocabulary.count)
        let normalizer = LogitMath.logSumExp(logits, scratch: session.scratch)
        parkRequested = false
        if beam.remaining(required).isEmpty {
            expandFree(beam, parent: parent, logits: logits, normalizer: normalizer, into: &children)
        } else {
            expandConstrained(beam, parent: parent, logits: logits, normalizer: normalizer, into: &children)
        }
        if parkRequested { park(beam, row: row, slot: slot) }
    }

    private func expandFree(
        _ beam: Beam, parent: Int, logits: UnsafeBufferPointer<Float>, normalizer: Float, into children: inout [Beam]
    ) {
        let avoidsTics = request.avoidsTics
        let ranked = LogitMath.topK(logits, k: topK + 16).filter {
            !vocabulary.isBanned($0.token) && !(avoidsTics && vocabulary.isTic($0.token))
        }
        guard let best = ranked.first else { return }
        let bestProbability = exp(Double(best.logit - normalizer))
        let ratio = request.textAfter.isEmpty ? request.tuning.confidenceRatio : request.tuning.midLineConfidenceRatio
        let losesConfidence = beam.probabilityCount > 0 && bestProbability < ratio * beam.meanProbability
        let narrowedUnsure = isNarrowed && bestProbability < request.tuning.narrowedStopProbability
        if inline, losesConfidence || narrowedUnsure {
            finish(beam, trim: continuesWord(best.token))
            return
        }
        if beam.pendingSentenceEnd, vocabulary.isEndOfGeneration(best.token) || startsWithWhitespace(best.token) {
            finish(beam, trim: false)
            return
        }
        var parentFinished = false
        var kept = 0
        let floor = inline ? request.tuning.probabilityFloor : 0
        for (rank, option) in ranked.enumerated() where kept < topK {
            let logprob = Double(option.logit - normalizer)
            if rank > 0, exp(logprob) < floor { break }
            let token = option.token
            let endsText = vocabulary.isEndOfGeneration(token)
            if endsText || isParagraphBreak(vocabulary.piece(token), after: beam) {
                if !inline, TextRules.wordUnits(text(of: beam)) < Self.draftMinimumWords { continue }
            }
            if endsText {
                finishParent(beam, &parentFinished)
                continue
            }
            let piece = vocabulary.piece(token)
            if token == beam.tokens.last, piece.contains(Self.space) || beam.tokens.dropLast().last == token { continue }
            if let newline = piece.firstIndex(of: Self.newline) {
                if inline || isParagraphBreak(piece, after: beam) || closesDraft(beam, with: piece[..<newline]) {
                    if newline == piece.startIndex {
                        finishParent(beam, &parentFinished)
                    } else {
                        finish(beam, extra: Array(piece[..<newline]), extraLogprob: logprob, trim: false)
                    }
                    continue
                }
            }
            var child = beam.extended(with: token, piece: piece, logprob: logprob, parent: parent)
            child.probabilitySum += exp(logprob)
            child.probabilityCount += 1
            if beam.tokens.isEmpty { child.firstProbability = exp(logprob) }
            guard admit(&child, parent: beam, parentFinished: &parentFinished) else { continue }
            children.append(child)
            kept += 1
        }
    }

    private func expandConstrained(
        _ beam: Beam, parent: Int, logits: UnsafeBufferPointer<Float>, normalizer: Float, into children: inout [Beam]
    ) {
        let remaining = Array(beam.remaining(required))
        var options: [TokenLogit]
        if let listed = vocabulary.tokens(satisfying: remaining, limit: Self.constrainedListLimit) {
            options = listed.map { TokenLogit(token: $0, logit: logits[Int($0)]) }
        } else {
            options = LogitMath.topK(logits, k: Self.constrainedScanSize).filter {
                !vocabulary.isBanned($0.token) && !vocabulary.isEndOfGeneration($0.token)
                    && pieceSatisfies(vocabulary.piece($0.token), remaining)
            }
        }
        options.sort { $0.logit > $1.logit }
        // Share of the model's probability on tokens that fit what was typed; the first token's
        // probability is taken within it, so a half-typed word does not read as low confidence.
        let fitting = beam.tokens.isEmpty ? options.reduce(0.0) { $0 + exp(Double($1.logit - normalizer)) } : 0
        var parentFinished = false
        for option in options.prefix(topK) {
            let piece = vocabulary.piece(option.token)
            let overflow = piece.dropFirst(remaining.count)
            if overflow.contains(Self.newline) { continue }
            let logprob = Double(option.logit - normalizer)
            var child = beam.extended(with: option.token, piece: piece, logprob: logprob, parent: parent)
            if beam.tokens.isEmpty, fitting > 0 { child.firstProbability = exp(logprob) / fitting }
            if !overflow.isEmpty {
                child.probabilitySum += exp(logprob)
                child.probabilityCount += 1
                guard admit(&child, parent: beam, parentFinished: &parentFinished) else { continue }
            }
            children.append(child)
        }
    }

    private func admit(_ child: inout Beam, parent: Beam, parentFinished: inout Bool) -> Bool {
        let text = text(of: child)
        if doublesSpace(text) { return false }
        if TextRules.wordUnits(text) > maxWords {
            if !parentFinished {
                parentFinished = true
                parkRequested = true
            }
            return false
        }
        child.pendingSentenceEnd = false
        if let stop = stopIndex(in: text) {
            record(String(text[..<stop]), path: child.path, first: child.firstProbability)
            return false
        }
        if request.tuning.blocksEchoes, let start = TextRules.echoStart(text, source: echoSource, sourceGrams: echoGrams) {
            if !inline { record(TextRules.trimmingToBoundary(String(text[..<start])), path: parent.path, first: parent.firstProbability) }
            return false
        }
        guard inline else { return true }
        if TextRules.repeatsLastBigram(text) { return false }
        guard TextRules.hasWordCharacter(text) else { return true }
        switch TextRules.sentenceEnd(of: text) {
        case .definite:
            finish(child, trim: false)
            return false
        case .ambiguous:
            child.pendingSentenceEnd = true
            return true
        case .none:
            return true
        }
    }

    /// Undertow's personal model: p(t) = (1 - lambda) * model(t) + personal(t), where `personal` puts
    /// weight on finishing a name or jargon word the person uses and on the word they usually write next.
    private func applyBias(to row: UnsafeMutablePointer<Float>, for beam: Beam) {
        guard let bias = request.bias, bias.strength != 0, beam.remaining(required).allSatisfy({ $0 == Self.space }) else { return }
        let pull = Float(bias.strength)
        func ws(_ b: UInt8) -> Bool { b == 32 || b == 10 || b == 9 }
        let text = Array(prompt.body.suffix(48)) + beam.bytes
        var i = text.count
        while i > 0, !ws(text[i - 1]) { i -= 1 }
        let current = text[i...]
        var j = i
        while j > 0, ws(text[j - 1]) { j -= 1 }
        var k = j
        while k > 0, !ws(text[k - 1]) { k -= 1 }
        func key(_ bytes: ArraySlice<UInt8>) -> String {
            String(decoding: bytes, as: UTF8.self).lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" }
        }
        var mass: [Int32: Float] = [:]
        var lambda: Float = 0
        var damp: [Int32] = []

        // Finishing the current word. Weight = share of this person's words with this prefix that are
        // names or jargon, so "Kav" -> Kavitha is near-certain while "th" stays the model's.
        if current.count >= 2 {
            var all: Float = 0, rare: Float = 0
            var hits: [(rest: [UInt8], count: Float)] = []
            for word in bias.words where word.bytes.starts(with: current) {
                all += word.count
                if word.unusual, word.bytes.count > current.count {
                    rare += word.count
                    hits.append((Array(word.bytes[current.count...]), word.count))
                }
            }
            if rare > 0 {
                let weight = min(0.95, pull * 0.92 * rare / (all + 1.5))
                for hit in hits {
                    // The longest token that is a prefix of what is left of the word.
                    let options = vocabulary.tokens(satisfying: hit.rest, limit: .max) ?? []
                    let best = options.filter { vocabulary.piece($0).count <= hit.rest.count }
                        .max { vocabulary.piece($0).count < vocabulary.piece($1).count }
                    if let best { mass[best, default: 0] += weight * hit.count / rare }
                }
                lambda += weight
            }
        }

        // Starting the next word, given the one before it.
        let bare = text.last.map(ws) ?? true
        let previous = bare ? key(text[k..<j]) : key(current)
        if !previous.isEmpty {
            for (word, p) in bias.followers[previous] ?? [:] {
                guard let token = session.firstToken(of: word, spaced: !bare) else { continue }
                mass[token, default: 0] += pull * 0.5 * Float(p)
                lambda += pull * 0.5 * Float(p)
            }
            for word in bias.rejected[previous] ?? [] {
                if let token = session.firstToken(of: word, spaced: !bare) { damp.append(token) }
            }
        }
        lambda = min(lambda, 0.95)
        for token in damp { row[Int(token)] -= 2.5 }
        guard !mass.isEmpty else { return }
        let normalizer = LogitMath.logSumExp(UnsafeBufferPointer(start: row, count: vocabulary.count), scratch: session.scratch)
        for (token, m) in mass where !vocabulary.isBanned(token) && !vocabulary.isEndOfGeneration(token) {
            let p = exp(row[Int(token)] - normalizer)
            row[Int(token)] = normalizer + log(p + m / (1 - lambda))
        }
    }

    // MARK: Finishing

    private func park(_ beam: Beam, row: UnsafeMutablePointer<Float>, slot existing: Int?) {
        guard parks, beam.sequence != Session.baseSequence, let slot = existing ?? parkingSlot(for: beam) else {
            finish(beam, trim: false)
            return
        }
        if existing == nil { (session.row(slot)).update(from: row, count: vocabulary.count) }
        let id = nextParkedID
        nextParkedID += 1
        finish(beam, trim: false, parked: id)
        parked.append(ParkedBeam(id: id, beam: beam, slot: slot))
    }

    private func parkingSlot(for beam: Beam) -> Int? {
        if parked.count < Self.parkLimit, let slot = session.allocateRow() { return slot }
        // Not one parked during this expansion: its sequence is still a parent the selection reads.
        guard let weakest = parked.indices.filter({ !expanding.contains(parked[$0].beam.sequence) })
            .min(by: { score(parked[$0].beam.path) < score(parked[$1].beam.path) }),
              score(parked[weakest].beam.path) < score(beam.path) else { return nil }
        let evicted = parked.remove(at: weakest)
        session.releaseSequence(evicted.beam.sequence)
        for index in finished.indices where finished[index].parked == evicted.id { finished[index].parked = nil }
        return evicted.slot
    }

    private func finishAtLimit(_ beam: Beam, row: UnsafeMutablePointer<Float>) {
        let logits = UnsafeBufferPointer(start: row, count: vocabulary.count)
        let next = LogitMath.topK(logits, k: 16).first { !vocabulary.isBanned($0.token) }
        finish(beam, trim: next.map { continuesWord($0.token) } ?? true)
    }

    private func finishParent(_ beam: Beam, _ done: inout Bool) {
        guard !done else { return }
        done = true
        finish(beam, trim: false)
    }

    private func finish(_ beam: Beam, extra: [UInt8] = [], extraLogprob: Double? = nil, trim: Bool, parked: Int? = nil) {
        guard beam.remaining(required).isEmpty else { return }
        let text = TextRules.decodeComplete(beam.bytes.dropFirst(required.count) + extra)
        let path = extraLogprob.map { beam.path.appending(end: beam.bytes.count + extra.count, logprob: $0) } ?? beam.path
        record(trim ? TextRules.trimmingPartialWord(text) : text, path: path, parked: parked, first: beam.firstProbability)
    }

    private func record(_ text: String, path: ScoredPath, parked: Int? = nil, first: Double) {
        let text = TextRules.trimmingTrailingWhitespace(inline ? text : TextRules.truncatingAtRepeatedLine(text))
        guard TextRules.hasWordCharacter(text) else { return }
        finished.append(FinishedText(bytes: required + Array(text.utf8), path: path, parked: parked, first: first))
    }

    // MARK: Scoring and text

    /// Drafts rank by mean logprob so a long paragraph is not outranked by an early stop.
    private var lengthPenalty: Double { inline ? request.tuning.lengthPenalty : 1 }

    private func score(_ path: ScoredPath) -> Double {
        var logprob = path.logprob
        var tokens = path.ends.count
        for (end, tokenLogprob) in zip(path.ends, path.logprobs) {
            guard end <= anchor else { break }
            logprob -= tokenLogprob
            tokens -= 1
        }
        return LogitMath.normalizedScore(logprob: logprob, tokens: tokens, lengthPenalty: lengthPenalty)
    }

    private func text(of finished: FinishedText) -> String? {
        guard finished.bytes.count > required.count, finished.bytes.starts(with: required) else { return nil }
        let text = TextRules.decodeComplete(finished.bytes[required.count...])
        return TextRules.hasWordCharacter(text) && !doublesSpace(text) ? text : nil
    }

    /// After a lone space token the model often writes the next word with its own space.
    private func doublesSpace(_ text: String) -> Bool {
        spaceBeforeCandidates && text.first.map { $0.isWhitespace && !$0.isNewline } == true
    }

    private func text(of beam: Beam) -> String {
        guard beam.remaining(required).isEmpty else { return "" }
        return TextRules.decodeComplete(beam.bytes.dropFirst(required.count))
    }

    private func continuesWord(_ token: Int32) -> Bool {
        !vocabulary.isEndOfGeneration(token) && TextRules.continuesWord(vocabulary.pieceText(token))
    }

    /// Base models drift into unrelated text after a line break, so a long enough draft ends at one.
    private func closesDraft(_ beam: Beam, with head: ArraySlice<UInt8>) -> Bool {
        TextRules.wordUnits(text(of: beam) + String(decoding: head, as: UTF8.self)) >= Self.draftMinimumWords
    }

    private func isParagraphBreak(_ piece: ArraySlice<UInt8>, after beam: Beam) -> Bool {
        piece.contains(Self.newline) && TextRules.containsBlankLine(beam.bytes.suffix(8) + piece)
    }

    private func startsWithWhitespace(_ token: Int32) -> Bool {
        guard let first = vocabulary.piece(token).first else { return false }
        return first == Self.space || first == Self.newline || first == 0x09
    }
}
