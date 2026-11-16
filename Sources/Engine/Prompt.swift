import Foundation

/// Turns "what is on screen" into a model prompt. Pure functions; covered by Tools/bench.
enum Prompt {
    enum Style: String, CaseIterable { case raw, chat }

    /// Splits the text before the caret into the part fed to the model and the part the
    /// continuation must reproduce (trailing whitespace + the word being typed).
    /// Returns nil when there is nothing sensible to predict (e.g. inside a long URL).
    static func split(_ before: String) -> (stem: String, constraint: String)? {
        var i = before.endIndex
        while i > before.startIndex, !before[before.index(before: i)].isWhitespace { i = before.index(before: i) }
        let partial = before[i...]
        if partial.count > 28 { return nil }
        while i > before.startIndex, before[before.index(before: i)].isWhitespace { i = before.index(before: i) }
        let constraint = String(before[i...])
        if constraint.utf8.count > 60 { return (before, "") }
        return (String(before[..<i]), constraint)
    }

    /// Leading whitespace plus one word: what a single Tab accepts.
    static func nextWord(_ s: String) -> String {
        var i = s.startIndex
        while i < s.endIndex, s[i].isWhitespace { i = s.index(after: i) }
        while i < s.endIndex, !s[i].isWhitespace { i = s.index(after: i) }
        return String(s[..<i])
    }

    struct Context {
        var app = ""
        var title = ""
        var samples: [String] = []  // snippets of the user's own earlier writing
        var after = ""  // text following the caret
        var instructions = ""  // the user's own note about who they are and how they write
        var screen = ""  // text visible in the window near the caret, e.g. the message being answered
    }

    /// Everything that precedes the user's text. Must stay byte-stable while the user types in
    /// one field, otherwise the KV cache is thrown away on every keystroke.
    static func header(_ style: Style, _ c: Context = Context(), family: String = "gemma") -> String {
        switch style {
        case .raw:
            return ""
        case .chat:
            // The framing matters more than anything else here: left to itself a chat model
            // answers the text ("I'm happy to help...") instead of continuing it.
            var s = "Below is text that a person is typing right now"
            if !c.app.isEmpty { s += " in \(c.app)" }
            if !c.title.isEmpty { s += " (window: \(c.title))" }
            s += ". Predict the words this same person types next. Stay in their voice, person and "
                + "language. Never reply to the text, never address the writer, never add commentary, "
                + "and plain text only. Output the text from its beginning, then the continuation.\n"
            if !c.instructions.isEmpty { s += "\nAbout this person, in their own words: " + c.instructions + "\n" }
            if !c.samples.isEmpty {
                s += "\nOther things this person wrote, for vocabulary and tone:\n"
                s += c.samples.map { "- " + $0 }.joined(separator: "\n") + "\n"
            }
            if !c.screen.isEmpty {
                s += "\nText visible in the same window, such as the message being answered. It is context only; "
                    + "do not copy it:\n" + c.screen + "\n"
            }
            if !c.after.isEmpty { s += "\nText already present after the cursor (do not repeat it):\n" + c.after + "\n" }
            // Gemma 4 renamed the turn markers.
            return family == "gemma4"
                ? "<|turn>user\n" + s + "<turn|>\n<|turn>model\n"
                : "<start_of_turn>user\n" + s + "<end_of_turn>\n<start_of_turn>model\n"
        }
    }
}
