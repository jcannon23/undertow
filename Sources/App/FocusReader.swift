import AppKit
import ApplicationServices

/// One reading of the focused text field. Rects are in Accessibility coordinates
/// (origin at the top-left of the primary display).
struct FieldSnapshot {
    var pid: pid_t
    var bundleID: String
    var appName: String
    var element: AXUIElement
    var windowTitle = ""
    var role = ""
    var secure = false
    /// False when the app exposes no readable text; the coordinator then relies on its key buffer.
    var textAvailable = false
    var before = ""
    var after = ""
    var hasSelection = false
    var caret: CGRect?
    var fieldFrame: CGRect?
    var font: NSFont?
    var color: NSColor?

    func sameField(as o: FieldSnapshot?) -> Bool { o.map { CFEqual($0.element, element) } ?? false }
}

extension AXUIElement {
    func attr(_ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(self, name as CFString, &v) == .success ? v : nil
    }
    func string(_ name: String) -> String? { attr(name) as? String }
    func param(_ name: String, _ arg: AnyObject) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyParameterizedAttributeValue(self, name as CFString, arg, &v) == .success ? v : nil
    }
    func range(_ name: String) -> CFRange? {
        guard let v = attr(name), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        return AXValueGetValue(v as! AXValue, .cfRange, &r) ? r : nil
    }
    func settable(_ name: String) -> Bool {
        var b: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(self, name as CFString, &b) == .success && b.boolValue
    }
    var frame: CGRect? {
        guard let p = attr(kAXPositionAttribute), let s = attr(kAXSizeAttribute),
            CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID()
        else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pt)
        AXValueGetValue(s as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }
}

private func axRange(_ loc: Int, _ len: Int) -> AXValue {
    var r = CFRange(location: loc, length: len)
    return AXValueCreate(.cfRange, &r)!
}

private func rectValue(_ v: AnyObject?) -> CGRect? {
    guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var r = CGRect.zero
    guard AXValueGetValue(v as! AXValue, .cgRect, &r) else { return nil }
    // Apps answer "I don't know" with zero / absurd rects rather than an error.
    guard r.height > 2, r.height < 300, r.origin.x.isFinite, r.origin.y.isFinite,
        !(r.origin == .zero && r.width == 0)
    else { return nil }
    return r
}

/// Reads the focused field of the frontmost app through the Accessibility API.
/// All calls block on the target app, so everything here runs on `queue`.
final class FocusReader {
    let queue = DispatchQueue(label: "undertow.ax", qos: .userInteractive)
    private var prepared = Set<pid_t>()
    static let chromium: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser", "com.microsoft.edgemac",
        "company.thebrowser.Browser", "company.thebrowser.dia", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
        "org.chromium.Chromium", "com.openai.atlas", "ai.perplexity.comet",
    ]
    static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "io.alacritty", "com.github.wez.wezterm",
    ]
    private static let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"]
    private let tailChars = 6000

    private var secretChecked: (el: AXUIElement, secret: Bool)?

    /// Password, payment card and one-time-code fields that are not marked secure, told from the
    /// field's labels and identifiers. Checked once per field: it costs several round trips.
    private func looksSecret(_ el: AXUIElement) -> Bool {
        if let c = secretChecked, CFEqual(c.el, el) { return c.secret }
        func strings(_ name: String) -> [String] { el.attr(name) as? [String] ?? [] }
        let autofill = el.string("AXValueAutofillType")
        let ids = [el.string("AXDOMIdentifier"), el.string(kAXIdentifierAttribute)].compactMap { $0 } + strings("AXDOMClassList")
        let labels = [kAXPlaceholderValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute].compactMap { el.string($0) }
            + strings("AXUserInputLabels")
        let secret = SecretFieldHints.isCredentialAutofill(autofill) || SecretFieldHints.isPaymentAutofill(autofill)
            || ids.contains(where: SecretFieldHints.namesPaymentOrOneTimeCode)
            || labels.contains { SecretFieldHints.mentionsPassword($0) || SecretFieldHints.namesPaymentOrOneTimeCode($0) }
        secretChecked = (el, secret)
        return secret
    }

    func read(pid: pid_t, bundleID: String, appName: String) -> FieldSnapshot? {
        let app = AXUIElementCreateApplication(pid)
        if prepared.insert(pid).inserted {
            AXUIElementSetMessagingTimeout(app, 0.25)
            // Chromium and Electron build their accessibility tree only when asked to.
            if Self.chromium.contains(bundleID) {
                AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            } else {
                AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            }
        }
        guard let f = app.attr(kAXFocusedUIElementAttribute), CFGetTypeID(f) == AXUIElementGetTypeID() else { return nil }
        let el = f as! AXUIElement
        var s = FieldSnapshot(pid: pid, bundleID: bundleID, appName: appName, element: el)
        s.role = el.string(kAXRoleAttribute) ?? ""
        s.secure = el.string(kAXSubroleAttribute) == "AXSecureTextField" || looksSecret(el)
        if s.secure { return s }
        s.fieldFrame = el.frame
        if let w = app.attr(kAXFocusedWindowAttribute), CFGetTypeID(w) == AXUIElementGetTypeID() {
            s.windowTitle = (w as! AXUIElement).string(kAXTitleAttribute) ?? ""
        }

        let isText = Self.textRoles.contains(s.role)
        if let sel = el.range(kAXSelectedTextRangeAttribute), sel.location >= 0,
            isText || el.settable(kAXSelectedTextRangeAttribute) || el.settable(kAXValueAttribute)
        {
            readPlain(el, sel, into: &s)
        } else if s.role == "AXWebArea" || el.attr("AXSelectedTextMarkerRange") != nil {
            readMarkers(el, into: &s)
        } else if !isText {
            return nil  // a button, a list, a canvas: nothing to complete
        }
        if Self.terminals.contains(bundleID) {
            // A terminal's text is the whole scrollback, not what is being typed.
            s.textAvailable = false
            s.before = ""
            s.after = ""
        }
        return s
    }

    private func readPlain(_ el: AXUIElement, _ sel: CFRange, into s: inout FieldSnapshot) {
        let loc = sel.location
        s.hasSelection = sel.length > 0
        let total = (el.attr(kAXNumberOfCharactersAttribute) as? Int) ?? -1
        let start = max(0, loc - tailChars)
        if total >= 0, total <= 30_000, let v = el.string(kAXValueAttribute) {
            let ns = v as NSString
            if loc <= ns.length {
                s.before = ns.substring(with: NSRange(location: start, length: loc - start))
                s.after = ns.substring(with: NSRange(location: loc, length: min(600, ns.length - loc)))
                s.textAvailable = true
            }
        }
        if !s.textAvailable {
            if let b = el.param(kAXStringForRangeParameterizedAttribute, axRange(start, loc - start)) as? String {
                s.before = b
                s.textAvailable = true
                let n = total >= 0 ? min(600, total - loc) : 0
                if n > 0 { s.after = el.param(kAXStringForRangeParameterizedAttribute, axRange(loc, n)) as? String ?? "" }
            } else if let v = el.string(kAXValueAttribute) {
                let ns = v as NSString
                if loc <= ns.length {
                    s.before = ns.substring(with: NSRange(location: start, length: loc - start))
                    s.after = ns.substring(with: NSRange(location: loc, length: min(600, ns.length - loc)))
                    s.textAvailable = true
                }
            }
        }
        let count = total >= 0 ? total : loc + (s.after as NSString).length
        s.caret = caretRect(el, loc: loc, count: count, before: s.before)
        if s.caret == nil { s.caret = markerCaret(el) }
        readStyle(el, at: loc > 0 ? loc - 1 : 0, count: count, into: &s)
        if s.caret == nil, start == 0 { runCaret(el, into: &s) }
    }

    private func caretRect(_ el: AXUIElement, loc: Int, count: Int, before: String) -> CGRect? {
        let bounds = kAXBoundsForRangeParameterizedAttribute
        if let r = rectValue(el.param(bounds, axRange(loc, 0))) {
            return CGRect(x: r.minX, y: r.minY, width: 0, height: r.height)
        }
        if loc > 0, before.last?.isNewline != true, let r = rectValue(el.param(bounds, axRange(loc - 1, 1))) {
            return CGRect(x: r.maxX, y: r.minY, width: 0, height: r.height)
        }
        if loc < count, let r = rectValue(el.param(bounds, axRange(loc, 1))) {
            return CGRect(x: r.minX, y: r.minY, width: 0, height: r.height)
        }
        return nil
    }

    // WebKit (and Chromium for some nodes) describe carets with opaque text markers.
    private func markerCaret(_ el: AXUIElement) -> CGRect? {
        guard let mr = el.attr("AXSelectedTextMarkerRange"),
            let r = rectValue(el.param("AXBoundsForTextMarkerRange", mr))
        else { return nil }
        return CGRect(x: r.maxX, y: r.minY, width: 0, height: r.height)
    }

    /// Font size last seen on a one-line text run, for reading wrapped runs.
    private var runFontSize: CGFloat = 14

    /// Embedded Chromium (Teams, Outlook) answers every range-bounds query with an empty rect, but
    /// the frame of each text run is right. Find the run holding the caret and measure into it.
    /// Needs `before` to hold the whole text up to the caret.
    private func runCaret(_ root: AXUIElement, into s: inout FieldSnapshot) {
        guard s.before.last?.isNewline != true else { return }  // an empty line has no run to measure
        var runs: [AXUIElement] = []
        var budget = 150
        func collect(_ e: AXUIElement) {
            budget -= 1
            guard budget > 0 else { return }
            if e.string(kAXRoleAttribute) == "AXStaticText" { return runs.append(e) }
            for k in e.attr(kAXChildrenAttribute) as? [AXUIElement] ?? [] { collect(k) }
        }
        collect(root)
        var left = s.before.unicodeScalars.filter { !CharacterSet.newlines.contains($0) }.count
        for run in runs {
            guard let text = run.string(kAXValueAttribute), let f = run.frame, f.height > 2 else { continue }
            let n = text.unicodeScalars.filter { !CharacterSet.newlines.contains($0) }.count
            if left > n { left -= n; continue }
            guard n == text.unicodeScalars.count else { return }
            let prefix = String(String.UnicodeScalarView(text.unicodeScalars.prefix(left)))
            let glyphH = 1.21 * runFontSize
            if f.height < glyphH * 1.5 {
                func width(_ t: String, _ size: CGFloat) -> CGFloat {
                    (t as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size)]).width
                }
                // The run's width gives the font size far more exactly than its height, and a
                // wrapped run breaks in the wrong place if the size is off by even a point.
                if text.count >= 12, text.last?.isWhitespace == false {
                    let size = (14 * f.width / width(text, 14) * 2).rounded() / 2
                    if size >= 9, size <= 40 { runFontSize = size }
                }
                let font = NSFont.systemFont(ofSize: runFontSize)
                func width(_ t: String) -> CGFloat { width(t, runFontSize) }
                let whole = width(text)
                s.caret = CGRect(x: f.minX + (whole > 0 ? width(prefix) / whole * f.width : 0), y: f.minY, width: 0, height: f.height)
                s.font = s.font ?? font
            } else if let parent = run.attr(kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID(),
                let block = (parent as! AXUIElement).frame, !prefix.isEmpty
            {
                // A wrapped run: break the lines the way the web view did and read off the last one.
                let font = NSFont.systemFont(ofSize: runFontSize)
                let storage = NSTextStorage(string: prefix, attributes: [.font: font])
                let lm = NSLayoutManager()
                let box = NSTextContainer(size: CGSize(width: block.width, height: .greatestFiniteMagnitude))
                box.lineFragmentPadding = 0
                lm.addTextContainer(box)
                storage.addLayoutManager(lm)
                let glyphs = lm.glyphRange(for: box)
                guard glyphs.length > 0 else { return }
                var lines = 0
                lm.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, _, _ in lines += 1 }
                let total = Int(((f.height - glyphH) / (glyphH * 1.18)).rounded()) + 1
                guard lines <= total, total > 1 else { return }
                let step = (f.height - glyphH) / CGFloat(total - 1)
                let end = lm.boundingRect(forGlyphRange: NSRange(location: glyphs.upperBound - 1, length: 1), in: box).maxX
                s.caret = CGRect(x: block.minX + end, y: f.minY + CGFloat(lines - 1) * step, width: 0, height: glyphH)
                s.font = s.font ?? font
            }
            return
        }
    }

    private func readMarkers(_ el: AXUIElement, into s: inout FieldSnapshot) {
        // Only editable web content: a page you are merely reading also has a "selection".
        guard el.attr("AXEditableAncestor") != nil || el.attr("AXHighestEditableAncestor") != nil,
            let mr = el.attr("AXSelectedTextMarkerRange")
        else { return }
        s.caret = markerCaret(el)
        if let sel = el.param("AXStringForTextMarkerRange", mr) as? String { s.hasSelection = !sel.isEmpty }
        if let start = el.attr("AXStartTextMarker"),
            let selStart = el.param("AXStartTextMarkerForTextMarkerRange", mr),
            let toCaret = el.param("AXTextMarkerRangeForUnorderedTextMarkers", [start, selStart] as CFArray),
            let text = el.param("AXStringForTextMarkerRange", toCaret) as? String
        {
            s.before = String(text.suffix(tailChars))
            s.textAvailable = true
            if s.caret == nil, text.count <= tailChars { runCaret(el, into: &s) }
        }
    }

    private func readStyle(_ el: AXUIElement, at loc: Int, count: Int, into s: inout FieldSnapshot) {
        guard count > 0, loc < count,
            let a = el.param(kAXAttributedStringForRangeParameterizedAttribute, axRange(loc, 1)) as? NSAttributedString,
            a.length > 0
        else { return }
        let attrs = a.attributes(at: 0, effectiveRange: nil)
        if let f = attrs[NSAttributedString.Key("AXFont")] as? [String: Any],
            let size = (f["AXFontSize"] as? NSNumber)?.doubleValue, size >= 6, size <= 120
        {
            let name = f["AXFontName"] as? String ?? ""
            s.font = NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size)
        }
        if let c = attrs[NSAttributedString.Key("AXForegroundColor")],
            CFGetTypeID(c as CFTypeRef) == CGColor.typeID
        {
            s.color = NSColor(cgColor: c as! CGColor)
        }
    }
}

/// Tells us when the focused app changed something, so we re-read promptly instead of polling.
final class FocusObserver {
    private var observer: AXObserver?
    private var pid: pid_t = 0
    var onChange: (() -> Void)?

    func watch(pid: pid_t) {
        guard pid != self.pid else { return }
        stop()
        self.pid = pid
        var obs: AXObserver?
        let cb: AXObserverCallback = { _, _, _, refcon in
            Unmanaged<FocusObserver>.fromOpaque(refcon!).takeUnretainedValue().onChange?()
        }
        guard AXObserverCreate(pid, cb, &obs) == .success, let obs else { return }
        let app = AXUIElementCreateApplication(pid)
        let me = Unmanaged.passUnretained(self).toOpaque()
        for n in [kAXFocusedUIElementChangedNotification, kAXValueChangedNotification, kAXSelectedTextChangedNotification,
            kAXFocusedWindowChangedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification]
        {
            AXObserverAddNotification(obs, app, n as CFString, me)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        observer = obs
    }

    func stop() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil
        pid = 0
    }
}
