// Adapted from Ghostwriter (https://github.com/mshll/ghostwriter), GPL-3.0. Changed for Undertow, 2026-11.
import Foundation

public struct EngineConfig: Sendable, Hashable {
    public var contextSize: Int = 4096
    public var batchSize: Int = 512
    public var microBatchSize: Int?
    public var threads: Int = 2
    public var batchThreads: Int = 4
    public var gpuLayers: Int = -1
    public var flashAttention: Bool = true
    /// Prompt tokens decoded per unit while staging a prompt (`CompletionEngine.stage`) as the user types (a
    /// request arrived within the last second). A keystroke waits for at most the unit in progress, since Metal
    /// does not stop a running decode; smaller units cost keystrokes less and stage more slowly. Idle, staging
    /// decodes 128 tokens per unit.
    public var stagingChunk: Int = 32

    public init() {}
}

public struct LoadedModelInfo: Sendable, Hashable {
    public var name: String
    public var parameterCount: Int64
    public var sizeBytes: Int64
    public var vocabSize: Int
}

/// Beam-search knobs; defaults come from gw-eval runs.
public struct SearchTuning: Sendable, Hashable {
    public var lengthPenalty: Double = 0.7
    public var probabilityFloor: Double = 0.05
    public var confidenceRatio: Double = 0
    public var midLineConfidenceRatio: Double = 0.7
    public var narrowAfterSteps: Int?
    public var narrowedStopProbability: Double = 0.3
    public var maxCandidates: Int = 6
    public var earlyStopMargin: Double? = 0
    public var midLineContextTokens: Int = 1
    public var blocksEchoes: Bool = true
    public var midLineCandidates: Int = 3
    public var midLineWordBonus: Double = 2
    public var midLineMargin: Double = 0
    /// Beam width when text follows the caret; nil keeps the request's width.
    public var midLineBeams: Int? = 4
    public var reusesBeams = true

    public init() {}
}

public struct BeamRequest: Sendable, Hashable {
    public enum Mode: Sendable, Hashable { case inline, draft }

    /// Full prompt; ends with the text before the caret minus `partialWord`.
    public var prompt: String
    public var partialWord: String
    public var textAfter: String
    public var maxWords: Int
    public var mode: Mode
    public var beams: Int
    public var topK: Int
    public var bias: TokenBias?
    public var tuning: SearchTuning
    public var stopStrings: [String]
    /// Keep out characters that instruction-tuned models love and people rarely type in prose
    /// (curly quotes, long dashes, markdown, emoji). Undertow sets it unless the person's text uses them.
    public var avoidsTics = false

    public init(
        prompt: String, partialWord: String = "", textAfter: String = "", maxWords: Int,
        mode: Mode = .inline, beams: Int = 6, topK: Int = 20, bias: TokenBias? = nil,
        tuning: SearchTuning = SearchTuning(), stopStrings: [String] = []
    ) {
        self.prompt = prompt
        self.partialWord = partialWord
        self.textAfter = textAfter
        self.maxWords = maxWords
        self.mode = mode
        self.beams = beams
        self.topK = topK
        self.bias = bias
        self.tuning = tuning
        self.stopStrings = stopStrings
    }
}

/// One person's word habits (Undertow's personal model), blended into the search's probabilities.
public struct TokenBias: Sendable, Hashable {
    public struct Word: Sendable {
        public var bytes: [UInt8]
        public var count: Float
        /// A name or a piece of jargon the model cannot know.
        public var unusual: Bool
    }

    /// previous word (lowercased) -> words that tend to follow it, with P(next | previous).
    public var followers: [String: [String: Double]]
    /// Every word the person has written.
    public var words: [Word] = []
    /// previous word (lowercased) -> suggestions the person keeps turning down there.
    public var rejected: [String: Set<String>] = [:]
    /// 0 off, 1 normal.
    public var strength: Double
    /// Stands for the contents when two biases are compared, which happens on every request.
    public var id = 0

    public init(followers: [String: [String: Double]], strength: Double) {
        self.followers = followers
        self.strength = strength
    }

    public static func == (a: TokenBias, b: TokenBias) -> Bool { a.id == b.id && a.strength == b.strength }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

public struct Candidate: Sendable, Hashable {
    /// Text to insert at the caret (excludes the already-typed partial word).
    public var text: String
    public var score: Double
    /// Probability of the candidate's first token, among the tokens that fit what was typed.
    public var firstProbability = 0.0

    public init(text: String, score: Double) {
        self.text = text
        self.score = score
    }
}

public struct SuggestionUpdate: Sendable, Hashable {
    public var candidates: [Candidate]
    public var isFinal: Bool
    public var milliseconds: Double
    public var reused: Bool
}

public struct SuggestionSubscription: Sendable {
    public let id: Int
    public let updates: AsyncStream<SuggestionUpdate>
}

public struct Publication: Sendable, Hashable {
    public var request: Int
    public var update: SuggestionUpdate
}

public struct EngineUnit: Sendable {
    public var milliseconds: Double
    public var publications: [Publication]
    public var staged = false
}

public struct GenerationStats: Sendable, Hashable {
    public var promptTokens = 0
    public var reusedTokens = 0
    public var tokenizeMilliseconds = 0.0
    public var prefillMilliseconds = 0.0
    public var steps = 0
    public var searchMilliseconds = 0.0
    public var rerankMilliseconds = 0.0
    public var totalMilliseconds = 0.0

    public init() {}
}

public enum InferenceError: Error, LocalizedError {
    case modelLoadFailed(String)
    case unsupportedModel(String)
    case contextCreationFailed
    case notLoaded
    case decodeFailed(Int32)
    case checksumMismatch(expected: String, actual: String)
    case downloadFailed(String)
    case alreadyDownloading(String)
    case insufficientSpace(needed: Int64, available: Int64)

    public var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let fileName): "Could not load the model \(fileName)."
        case .unsupportedModel(let reason): "This model is not supported: \(reason)."
        case .contextCreationFailed: "Could not create an inference context."
        case .notLoaded: "No model is loaded."
        case .decodeFailed(let code): "Decoding failed (code \(code))."
        case .checksumMismatch(let expected, let actual): "Checksum mismatch: expected \(expected), got \(actual)."
        case .downloadFailed(let reason): "Download failed: \(reason)."
        case .alreadyDownloading(let name): "\(name) is already downloading."
        case .insufficientSpace(let needed, let available):
            "Not enough free disk space: the download needs \(Self.bytes(needed)) and \(Self.bytes(available)) is available."
        }
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
