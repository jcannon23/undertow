import AppKit
import ApplicationServices

/// The brain. Keeps an optimistic model of "the text before the caret", asks the engine for a
/// continuation whenever that changes, and decides what Tab means. Main thread only.
final class Coordinator: ObservableObject {
    enum ModelState: Equatable { case missing, loading, ready(String), failed(String), asleep }

    let settings = Settings.shared
    let engine = LlamaEngine()
    let style = StyleStore()
    let tap = KeyTap()
    let downloader = ModelDownloader()
    private let reader = FocusReader()
    private let observer = FocusObserver()
    private let overlay = GhostOverlay()

    @Published private(set) var modelState = ModelState.missing
    @Published private(set) var trusted = AXIsProcessTrusted()

    // Belief about the focused field.
    private var snap: FieldSnapshot?
    private var before = ""
    private var header = ""
    private var keysInField = 0

    // What is on screen.
    private var ghost = ""
    private var kind = GhostKind.completion
    private var fix: Typo.Fix?
    private var choices: [String] = []
    private var choicePrefix = ""

    // Bookkeeping.
    private var lastInput = Date.distantPast
    private var predictedFor: String?
    private var suppressed = false  // Esc: stay quiet until the text changes
    private var caretStale = false  // text changed under us; wait for a fresh caret before drawing
    private var reading = false
    private var observerReadPending = false
    private var rereadWanted = false
    private var family = "gemma"
    private var promptStyle = Prompt.Style.chat
    /// The suggestion currently on screen, until we learn whether the user wanted it.
    private var pending: (prev: String, word: String, left: Int, confidence: Float, app: String, shown: Date)?
    private var idleTimer: Timer?
    private var pressure: DispatchSourceMemoryPressure?

    // MARK: lifecycle

    func start() {
        tap.onKey = { [weak self] in self?.handleKey($0) ?? false }
        tap.onPointer = { [weak self] in self?.handlePointer($0) }
        observer.onChange = { [weak self] in
            // Apps fire these in bursts (and some fire them at us for our own reads): one read per burst.
            guard let self, !self.observerReadPending else { return }
            self.observerReadPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { self.observerReadPending = false; self.read() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.clearGhost()
            self?.scheduleRead(0.05)
        }
        // Give the RAM back when nobody has typed for a while, or the moment the system is short.
        idleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self, case .ready = self.modelState, Date().timeIntervalSince(self.lastInput) > 20 * 60 else { return }
            self.sleepModel()
        }
        let p = DispatchSource.makeMemoryPressureSource(eventMask: .critical, queue: .main)
        p.setEventHandler { [weak self] in self?.sleepModel() }
        p.resume()
        pressure = p
        downloader.onInstalled = { [weak self] _ in
            guard let self else { return }
            self.objectWillChange.send()
            if !self.ready { self.loadModel() }
        }
        if Log.on { engine.trace = { Log.d("engine " + $0) } }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.harvest()
            self?.style.save()
        }
        refreshLM()
        refreshTrust()
        Settings.adoptBundledModels()
        loadModel()
        // Slim install with no model anywhere: fetch the recommended one without being asked.
        if modelState == .missing { downloader.start(ModelOption.catalog[0]) }
    }

    /// Hands the engine a fresh snapshot of everything learned about this user's writing.
    func refreshLM() {
        engine.setPersonalLM(settings.learnStyle ? style.personalLM() : PersonalLM())
    }

    /// The user looked at a suggestion and took it, or typed past it. Both are lessons.
    private func resolve(taken: Bool) {
        guard let p = pending else { return }
        pending = nil
        guard settings.learnStyle, taken || Date().timeIntervalSince(p.shown) > 0.25 else { return }  // too fast to have read it
        Log.d("feedback \(taken ? "taken" : "rejected") \(p.prev)>\(p.word) p=\(p.confidence)")
        if style.record(app: p.app, confidence: p.confidence, taken: taken, prev: p.prev, word: p.word) { refreshLM() }
    }

    /// Re-checks Accessibility permission and (re)starts the key tap once granted.
    func refreshTrust() {
        trusted = AXIsProcessTrusted()
        if trusted, !tap.isRunning { let ok = tap.start(); Log.d("tap start \(ok)"); scheduleRead(0.1) }
    }

    func loadModel() {
        guard let url = settings.resolvedModel() else { modelState = .missing; return }
        if modelState == .loading { return }
        modelState = .loading
        clearGhost()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                try engine.load(path: url.path)
                let fam = engine.family
                DispatchQueue.main.async {
                    self.family = fam
                    self.modelState = .ready(url.lastPathComponent)
                    self.rebuildHeader()
                    self.predictedFor = nil
                    self.scheduleRead(0)
                }
            } catch {
                DispatchQueue.main.async { self.modelState = .failed(url.lastPathComponent) }
            }
        }
    }

    private func sleepModel() {
        guard case .ready = modelState else { return }
        clearGhost()
        modelState = .asleep
        DispatchQueue.global().async { self.engine.unload() }
    }

    private var ready: Bool { if case .ready = modelState { return true }; return false }

    // MARK: keyboard

    private func handleKey(_ e: CGEvent) -> Bool {
        guard settings.enabled else { return false }
        if modelState == .asleep { loadModel() }
        let code = e.getIntegerValueField(.keyboardEventKeycode)
        let f = e.flags
        let command = f.contains(.maskCommand) || f.contains(.maskControl)
        Log.d("keycode \(code) flags=\(String(f.rawValue, radix: 16)) visible=\(overlay.visible)")

        if code == 48, !command {  // Tab
            if f.contains(.maskAlternate) { return showChoices() }
            if overlay.visible {
                switch kind {
                case .completion: accept(all: f.contains(.maskShift))
                case .fix: applyFix()
                case .choices: pick(0)
                }
                return true
            }
        }
        if code == 53, overlay.visible {  // Esc
            resolve(taken: false)
            clearGhost()
            suppressed = true
            return true
        }
        if kind == .choices, overlay.visible, !command, let n = Int(e.typedString), n >= 1, n <= choices.count {
            pick(n - 1)
            return true
        }

        // Everything below passes through to the app; we only update our belief.
        lastInput = Date()
        if command {
            clearGhost()  // paste, undo, select-all, app shortcuts
            scheduleRead(0.04)
            scheduleRead(0.2)
            return false
        }
        switch code {
        case 51:  // delete
            if f.contains(.maskAlternate) || before.isEmpty { clearGhost(); before = snap?.textAvailable == true ? before : "" } else {
                before.removeLast()
                textChanged()
            }
        case 36, 76, 48, 115...126:  // return, enter, tab, arrows, home/end/page keys, forward delete
            clearGhost()
            if snap?.textAvailable != true { before = "" }  // key-buffer apps: a new line starts fresh
        default:
            let s = e.typedString
            guard let u = s.unicodeScalars.first, u.value >= 0x20, u.value != 0x7F, !(0xF700...0xF8FF).contains(u.value) else { break }
            typed(s)
        }
        scheduleRead(0.012)
        scheduleRead(0.09)
        return false
    }

    private func typed(_ s: String) {
        Log.d("key ⟦\(s)⟧")
        keysInField += 1
        suppressed = false
        before += s
        if kind == .completion, !ghost.isEmpty, ghost.hasPrefix(s) {
            // Typing along with the suggestion: no model call, just slide.
            ghost.removeFirst(s.count)
            overlay.advance(typed: s, remaining: ghost)
            if ghost.isEmpty { caretStale = true }
            if pending != nil {
                pending!.left -= s.count
                if pending!.left <= 0 { resolve(taken: true) }  // typed the suggested word out by hand
            }
            if wordCount(ghost) < 3 { predict() }
            return
        }
        if kind == .completion, !ghost.isEmpty { resolve(taken: false) }
        textChanged()
        if settings.typoFix, let f = Typo.check(before) { showFix(f) }
    }

    /// `before` changed in a way the current ghost does not survive.
    private func textChanged() {
        suppressed = false
        clearGhost()
        caretStale = true
        predict()
    }

    private func handlePointer(_ type: CGEventType) {
        switch type {
        case .scrollWheel:
            if overlay.visible { overlay.hide() }  // text moved under us; the re-read redraws it
            scheduleRead(0.18)
        case .leftMouseUp:
            scheduleRead(0.03)
            scheduleRead(0.15)
        default:
            clearGhost()
        }
    }

    // MARK: reading the field

    private func scheduleRead(_ delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.read() }
    }

    private func read() {
        guard trusted, settings.enabled else { return }
        if reading { rereadWanted = true; return }
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        let bundle = app.bundleIdentifier ?? ""
        let name = app.localizedName ?? ""
        observer.watch(pid: pid)
        reading = true
        let started = Date()
        reader.queue.async { [self] in
            let s = settings.allows(bundle) ? reader.read(pid: pid, bundleID: bundle, appName: name) : nil
            DispatchQueue.main.async {
                self.reading = false
                self.apply(s, started: started)
                if self.rereadWanted { self.rereadWanted = false; self.read() }
            }
        }
    }

    private func apply(_ s: FieldSnapshot?, started: Date) {
        if Log.on {
            Log.d(s.map { "read \($0.bundleID) \($0.role) text=\($0.textAvailable) sel=\($0.hasSelection) secure=\($0.secure) caret=\($0.caret.map { "\(Int($0.minX)),\(Int($0.minY)) h\(Int($0.height))" } ?? "nil") font=\($0.font.map { "\($0.fontName) \($0.pointSize)" } ?? "nil") before=…\($0.before.suffix(30))| after=\($0.after.prefix(12)) \(Int(Date().timeIntervalSince(started) * 1000))ms" } ?? "read nil")
        }
        guard let s, !s.secure else {
            harvest()
            snap = nil
            before = ""
            clearGhost()
            return
        }
        let newField = !s.sameField(as: snap)
        if newField {
            Log.d("new field (was \(snap?.role ?? "none"))")
            harvest()
            clearGhost()
            keysInField = 0
            suppressed = false
            predictedFor = nil
            before = s.textAvailable ? s.before : ""
            snap = s
            caretStale = false
            rebuildHeader()
        } else if s.textAvailable, s.before != before {
            // The app may simply not have processed keys we already counted.
            if before.hasPrefix(s.before), Date().timeIntervalSince(lastInput) < 0.4 { scheduleRead(0.03); return }
            if before.count > 60, s.before.count < 8 { harvest() }  // message sent / field cleared
            let added = s.before.hasPrefix(before) ? String(s.before.dropFirst(before.count)) : nil
            before = s.before
            if let added, kind == .completion, !ghost.isEmpty, ghost.hasPrefix(added) {
                ghost.removeFirst(added.count)
            } else {
                clearGhost()
            }
            snap = s
            caretStale = false
        } else {
            // Same text. Without readable text we can only trust a reading taken after the last key.
            if s.textAvailable || started > lastInput.addingTimeInterval(0.008) { caretStale = false }
            let old = snap
            snap = s
            if s.caret == nil { snap?.caret = old?.caret }
            if s.font == nil { snap?.font = old?.font; snap?.color = old?.color }
        }

        // Only complete at the end of a line: ghost text over existing text is unreadable.
        let restOfLine = s.after.prefix { !$0.isNewline }
        if s.hasSelection || !restOfLine.allSatisfy(\.isWhitespace) { clearGhost(); return }
        if !ghost.isEmpty || kind != .completion { render() }
        if ghost.isEmpty, kind == .completion, predictedFor != before { predict() }
    }

    private func rebuildHeader() {
        guard let s = snap else { header = ""; return }
        var c = Prompt.Context()
        c.app = s.appName
        c.title = String(s.windowTitle.prefix(80))
        c.after = String(s.after.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        if settings.learnStyle { c.samples = style.relevant(app: s.bundleID, context: s.before + " " + s.windowTitle) }
        header = Prompt.header(promptStyle, c, family: family)
    }

    /// Remember what was written in the field we are leaving (if the user really typed it).
    private func harvest() {
        guard settings.learnStyle, keysInField >= 25, let s = snap, !s.secure, !before.isEmpty else { return }
        keysInField = 0
        style.add(before, app: s.bundleID)
        refreshLM()
    }

    // MARK: predicting

    private func predict() {
        guard settings.enabled, ready, !suppressed, let s = snap, !s.secure else { return }
        guard before.contains(where: { !$0.isWhitespace }), let (stem, cons) = Prompt.split(before) else { return }
        predictedFor = before
        var r = CompletionRequest()
        r.header = header
        r.stem = stem
        r.constraint = cons
        r.maxTokens = settings.maxTokens
        if settings.learnStyle { r.minFirstProb = style.minConfidence(app: s.bundleID) }
        let base = before
        let extending = !ghost.isEmpty
        engine.complete(r) { [weak self] c in
            DispatchQueue.main.async { self?.deliver(c, base: base, extending: extending) }
        }
    }

    private func deliver(_ c: Completion, base: String, extending: Bool) {
        guard before.hasPrefix(base) else { Log.d("drop: base gone"); return }
        let typedSince = before.dropFirst(base.count)
        guard c.text.hasPrefix(typedSince) else { Log.d("drop: typed ⟦\(typedSince)⟧ vs ⟦\(c.text)⟧"); return }  // the user went another way; a newer request is running
        let text = String(c.text.dropFirst(typedSince.count))
        if kind != .completion, overlay.visible { return }  // a fix or the word picker has the floor
        if extending, !ghost.isEmpty, !text.hasPrefix(ghost) { return }  // never rewrite what is being read
        if text.isEmpty {
            if !extending, c.done, typedSince.isEmpty { clearGhost() }
            return
        }
        kind = .completion
        ghost = text
        if c.done, !extending, typedSince.isEmpty, let s = snap {
            // Remember what we offered, keyed by the word before it, to learn from the outcome.
            let partial = String(base.reversed().prefix { !$0.isWhitespace }.reversed())
            let first = Prompt.nextWord(text)
            let prevWord = base.dropLast(partial.count).split(whereSeparator: \.isWhitespace).last ?? ""
            pending = (partial.isEmpty ? StyleStore.wordKey(prevWord) : "",
                first.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: .punctuationCharacters),
                first.count, c.confidence, s.bundleID, Date())
        }
        Log.d("ghost \(c.done ? "final" : "part") \(Int(c.ms))ms p=\(c.confidence) ⟦\(text)⟧ stale=\(caretStale)")
        render()
    }

    private func render() {
        guard let s = snap, !caretStale || overlay.visible else { return }
        let text: String
        switch kind {
        case .completion: text = ghost
        case .fix: text = fix?.right ?? ""
        case .choices: text = choices.map { choicePrefix + $0 }.joined(separator: "\u{1F}")
        }
        guard !text.isEmpty else { return overlay.hide() }
        var caret = s.caret
        var floating = false
        if caret == nil, let f = s.fieldFrame {
            // No caret from this app: hang a small card under the field instead.
            caret = CGRect(x: f.minX + 6, y: f.maxY - 20, width: 0, height: 18)
            floating = true
        }
        guard let caret else { return overlay.hide() }
        overlay.show(text, kind: kind, caret: caret, font: s.font, color: s.color, limitX: s.fieldFrame?.maxX,
            hint: settings.showHint, floating: floating)
    }

    private func clearGhost() {
        pending = nil
        engine.cancel()
        ghost = ""
        fix = nil
        choices = []
        kind = .completion
        overlay.hide()
    }

    private func wordCount(_ s: String) -> Int { s.split(whereSeparator: \.isWhitespace).count }

    // MARK: accepting

    private func accept(all: Bool) {
        let piece = all ? ghost : Prompt.nextWord(ghost)
        guard !piece.isEmpty else { return }
        Log.d("accept ⟦\(piece)⟧")
        resolve(taken: true)
        Typer.type(piece)
        lastInput = Date()
        keysInField += 1
        before += piece
        ghost.removeFirst(piece.count)
        settings.wordsAccepted += wordCount(piece)
        overlay.advance(typed: piece, remaining: ghost)
        if ghost.isEmpty { caretStale = true }
        if wordCount(ghost) < 3 { predict() }
        scheduleRead(0.03)
        scheduleRead(0.14)
    }

    private func showFix(_ f: Typo.Fix) {
        engine.cancel()
        fix = f
        ghost = ""
        kind = .fix
        caretStale = false  // a card under the line tolerates a caret one character behind
        render()
    }

    private func applyFix() {
        guard let f = fix else { return }
        Typer.backspace(f.wrong.count + f.tail.count)
        Typer.type(f.right + f.tail)
        lastInput = Date()
        before = String(before.dropLast(f.wrong.count + f.tail.count)) + f.right + f.tail
        textChanged()
        scheduleRead(0.05)
        scheduleRead(0.2)
    }

    /// ⌥Tab: offer a few different next words. Returns whether the key was consumed.
    private func showChoices() -> Bool {
        guard ready, let s = snap, !s.secure, before.contains(where: { !$0.isWhitespace }) else { return false }
        var r = CompletionRequest()
        r.header = header
        // Always whole next words, never completions of the word under the caret.
        let ws = String(before.reversed().prefix { $0.isWhitespace }.reversed())
        r.stem = String(before.dropLast(ws.count))
        r.constraint = ws
        choicePrefix = ""
        let lead = ws.isEmpty ? " " : ""
        let base = before
        engine.alternatives(r, count: 3) { [weak self] words in
            DispatchQueue.main.async {
                guard let self, self.before == base, !words.isEmpty else { return }
                self.ghost = ""
                self.fix = nil
                self.choices = words
                self.choiceLead = lead
                self.kind = .choices
                self.caretStale = false
                self.render()
            }
        }
        return true
    }

    private var choiceLead = ""

    private func pick(_ i: Int) {
        guard i < choices.count else { return }
        let piece = choiceLead + choices[i]
        clearGhost()
        Typer.type(piece)
        lastInput = Date()
        before += piece
        settings.wordsAccepted += 1
        caretStale = true
        predict()
        scheduleRead(0.03)
        scheduleRead(0.14)
    }
}
