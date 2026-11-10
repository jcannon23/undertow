import AppKit
import CryptoKit
import Foundation
import Security

/// "Learn my style": remembers snippets the user actually typed and hands the most relevant ones
/// back as prompt context. Stored AES-GCM encrypted; the key lives in the login keychain.
/// Nothing here ever leaves the machine.
final class StyleStore {
    struct Snippet: Codable { var text: String; var app: String; var date: Date }

    private var snippets: [Snippet] = []
    private let file: URL
    private let maxSnippets = 400
    private lazy var key: SymmetricKey? = Self.loadKey()

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Undertow")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("style.bin")
        load()
    }

    var count: Int { snippets.count }

    func add(_ raw: String, app: String) {
        guard let text = Self.scrub(raw) else { return }
        // Re-harvesting a growing draft replaces its earlier, shorter self.
        snippets.removeAll { text.hasPrefix($0.text) || $0.text == text }
        snippets.append(Snippet(text: text, app: app, date: Date()))
        if snippets.count > maxSnippets { snippets.removeFirst(snippets.count - maxSnippets) }
        save()
    }

    func erase() {
        snippets = []
        try? FileManager.default.removeItem(at: file)
    }

    /// Up to `limit` snippets, preferring the same app and overlapping vocabulary.
    func relevant(app: String, context: String, limit: Int = 3) -> [String] {
        let ctx = Self.words(context)
        let now = Date()
        let scored = snippets.map { s -> (Double, String) in
            let w = Self.words(s.text)
            let overlap = ctx.isEmpty ? 0 : Double(ctx.intersection(w).count) / Double(max(1, min(ctx.count, w.count)))
            let recency = max(0, 1 - now.timeIntervalSince(s.date) / (30 * 86_400))
            return ((s.app == app ? 1.0 : 0) + 2 * overlap + 0.5 * recency, s.text)
        }
        return scored.sorted { $0.0 > $1.0 }.prefix(limit).map { String($0.1.suffix(260)) }
    }

    private static func words(_ s: String) -> Set<String> {
        Set(s.lowercased().split { !$0.isLetter }.filter { $0.count > 3 }.map(String.init))
    }

    // MARK: scrubbing

    private static let secretPatterns: [NSRegularExpression] = [
        #"\b[A-Za-z0-9+/_\-]{24,}={0,2}"#,  // long opaque tokens, base64, hashes
        #"\b(sk|pk|rk|ghp|gho|ghs|github_pat|xox[abpr]|AKIA|AIza|ya29)[-_A-Za-z0-9]{8,}"#,
        #"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#,  // JWT
        #"-----BEGIN [A-Z ]+-----"#,
        #"(?i)\b(pass(word|code)?|secret|token|api[_ -]?key|pin)\b\s*[:=]\s*\S+"#,
        #"\b(?:\d[ -]?){12,19}\b"#,  // card-like digit runs
        #"\b\d{3}-\d{2}-\d{4}\b"#,  // SSN
    ].map { try! NSRegularExpression(pattern: $0) }

    /// Returns text safe to keep, or nil if it is too short or looks like it carries a credential.
    static func scrub(_ raw: String) -> String? {
        let text = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).suffix(700))
        guard text.split(separator: " ").count >= 6 else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for p in secretPatterns where p.firstMatch(in: text, range: range) != nil { return nil }
        return text
    }

    // MARK: persistence

    private func load() {
        guard let key, let data = try? Data(contentsOf: file),
            let box = try? AES.GCM.SealedBox(combined: data),
            let plain = try? AES.GCM.open(box, using: key),
            let list = try? JSONDecoder().decode([Snippet].self, from: plain)
        else { return }
        snippets = list
    }

    private func save() {
        guard let key, let plain = try? JSONEncoder().encode(snippets),
            let box = try? AES.GCM.seal(plain, using: key), let data = box.combined
        else { return }
        try? data.write(to: file, options: [.atomic, .completeFileProtection])
    }

    private static func loadKey() -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.undertow.style",
            kSecAttrAccount as String: "style-key",
        ]
        var out: AnyObject?
        var q = query
        q[kSecReturnData as String] = true
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data { return SymmetricKey(data: d) }
        let key = SymmetricKey(size: .bits256)
        var add = query
        add[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess ? key : nil
    }
}

/// Inline typo fix for the word just finished, using the system spell checker (so it follows the
/// user's own dictionary and languages). Main thread only.
enum Typo {
    struct Fix { var wrong: String; var right: String; var tail: String }

    static func check(_ before: String) -> Fix? {
        // tail = the delimiter(s) just typed; word = what precedes them
        var i = before.endIndex
        while i > before.startIndex, let c = Optional(before[before.index(before: i)]), c == " " || ",.;:!?".contains(c) {
            i = before.index(before: i)
        }
        let tail = String(before[i...])
        guard !tail.isEmpty, tail.count <= 2 else { return nil }
        var j = i
        while j > before.startIndex, before[before.index(before: j)].isLetter || before[before.index(before: j)] == "'" {
            j = before.index(before: j)
        }
        let word = String(before[j..<i])
        // Leave names, acronyms, code and short words alone.
        guard word.count >= 4, word == word.lowercased() || word == word.capitalized,
            j == before.startIndex || before[before.index(before: j)].isWhitespace
        else { return nil }
        let checker = NSSpellChecker.shared
        let miss = checker.checkSpelling(of: word, startingAt: 0)
        guard miss.location != NSNotFound else { return nil }
        let r = NSRange(location: 0, length: (word as NSString).length)
        let lang = checker.language()
        let fix = checker.correction(forWordRange: r, in: word, language: lang, inSpellDocumentWithTag: 0)
            ?? checker.guesses(forWordRange: r, in: word, language: lang, inSpellDocumentWithTag: 0)?.first { editDistance($0.lowercased(), word.lowercased()) <= 2 }
        guard let fix, fix != word, !fix.contains(" ") else { return nil }
        return Fix(wrong: word, right: fix, tail: tail)
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in 0..<a.count {
            var prev = row[0]
            row[0] = i + 1
            for j in 0..<b.count {
                let cur = row[j + 1]
                row[j + 1] = min(cur + 1, row[j] + 1, prev + (a[i] == b[j] ? 0 : 1))
                prev = cur
            }
        }
        return row[b.count]
    }
}
