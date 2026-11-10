import AppKit

/// What the overlay is showing; decides both the look and what Tab does.
enum GhostKind: Equatable {
    case completion  // grey continuation, drawn as if it were already in the field
    case fix  // "→ receive": replaces the word just typed
    case choices  // "1 prompt  2 fast  3 speedy"
}

/// A click-through, never-key panel that draws the suggestion at the text caret.
final class GhostOverlay {
    private let panel: NSPanel
    private let view = GhostView()
    private(set) var visible = false
    private var anchor = CGRect.zero  // caret, AX coordinates
    private var nudge: CGFloat = 0  // optimistic x offset until the next real caret reading

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.contentView = view
    }

    /// `caret` and `limitX` are in AX coordinates. `limitX` is the right edge the text may not cross.
    func show(_ text: String, kind: GhostKind, caret: CGRect, font: NSFont?, color: NSColor?, limitX: CGFloat?, hint: Bool, floating: Bool = false) {
        guard !text.isEmpty else { return hide() }
        anchor = caret
        nudge = 0
        view.kind = kind
        view.floating = floating || kind != .completion
        view.font = font ?? Self.guessFont(lineHeight: caret.height)
        view.textColor = color
        view.showHint = hint
        view.text = text
        layout(limitX: limitX)
        if !visible {
            visible = true
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.10; panel.animator().alphaValue = 1 }
        }
        lastLimit = limitX
    }

    private var lastLimit: CGFloat?

    /// The user typed (or accepted) `typed`, which the suggestion began with: slide along
    /// immediately rather than waiting for the app to report the new caret.
    func advance(typed: String, remaining: String) {
        guard visible, !remaining.isEmpty else { return hide() }
        nudge += (typed as NSString).size(withAttributes: [.font: view.font]).width
        view.text = remaining
        layout(limitX: lastLimit)
    }

    func moveCaret(_ caret: CGRect, limitX: CGFloat?) {
        guard visible else { return }
        anchor = caret
        nudge = 0
        lastLimit = limitX
        layout(limitX: limitX)
    }

    func hide() {
        guard visible else { return }
        visible = false
        panel.orderOut(nil)
    }

    private func layout(limitX: CGFloat?) {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let x = anchor.minX + nudge
        let inline = !view.floating
        let screen = NSScreen.screens.first { $0.frame.insetBy(dx: -2, dy: -2).contains(CGPoint(x: x, y: primaryH - anchor.midY)) } ?? NSScreen.main
        let screenMaxX = screen?.frame.maxX ?? x + 800
        let maxX = inline ? min(limitX ?? screenMaxX, screenMaxX) - 4 : screenMaxX - 8
        let size = view.fit(maxWidth: max(40, maxX - x))
        let lineH = view.lineHeight
        var frame = CGRect(x: x, y: 0, width: ceil(size.width), height: ceil(size.height))
        if inline {
            // Put our baseline where the host app's is. AppKit text views report the whole line
            // fragment as the caret and sit the baseline a descender above its bottom; web
            // engines report the glyph box, centred on the line.
            let asc = view.font.ascender, desc = -view.font.descender
            let appKit = abs(NSLayoutManager().defaultLineHeight(for: view.font) - anchor.height) <= 1.5
            let baselineFromTop = appKit ? anchor.height - desc : (anchor.height - (asc + desc)) / 2 + asc
            let baselineY = primaryH - (anchor.minY + baselineFromTop)
            frame.origin.y = (baselineY - desc - (size.height - lineH) / 2).rounded()
        } else {
            frame.origin.y = primaryH - anchor.maxY - size.height - 4  // hang just below the line
            if let s = screen, frame.minY < s.visibleFrame.minY { frame.origin.y = primaryH - anchor.minY + 4 }
            if frame.maxX > screenMaxX - 8 { frame.origin.x = screenMaxX - 8 - frame.width }
        }
        panel.hasShadow = !inline
        panel.setFrame(frame, display: true)
        Log.d("overlay x=\(Int(frame.minX)) yTop=\(Int(primaryH - frame.maxY)) w=\(Int(frame.width)) h=\(Int(frame.height)) caret=\(Int(anchor.minX)),\(Int(anchor.minY)) h\(Int(anchor.height)) nudge=\(Int(nudge)) inline=\(inline) \(view.font.fontName) \(view.font.pointSize) ⟦\(view.text)⟧")
        view.needsDisplay = true
    }

    static func guessFont(lineHeight h: CGFloat) -> NSFont {
        let size = max(9, min(40, (h / 1.22 * 2).rounded() / 2))
        return NSFont.systemFont(ofSize: h > 2 ? size : 13)
    }
}

private final class GhostView: NSView {
    var text = ""
    var kind = GhostKind.completion
    /// Drawn as a small card below the line instead of inline (no trustworthy caret, or not a completion).
    var floating = false
    var font = NSFont.systemFont(ofSize: 13)
    var textColor: NSColor?
    var showHint = true
    private var shown = ""  // `text` truncated to whole words that fit

    var lineHeight: CGFloat { ceil(font.ascender - font.descender + font.leading) }
    private var pad: CGFloat { floating ? 7 : 0 }
    private var hintFont: NSFont { NSFont.systemFont(ofSize: max(8, font.pointSize * 0.62), weight: .medium) }
    private var hintGap: CGFloat { font.pointSize * 0.45 }

    private var ghostColor: NSColor {
        switch kind {
        case .completion where floating:
            return .secondaryLabelColor
        case .completion:
            // Tint from the field's own ink when the app tells us; mid-grey reads on light and dark.
            return (textColor?.usingColorSpace(.sRGB)).map { $0.withAlphaComponent(0.42) } ?? NSColor(white: 0.5, alpha: 0.85)
        case .fix, .choices:
            return .labelColor
        }
    }

    private func attributed(_ s: String) -> NSAttributedString {
        if kind == .choices {
            // "1 word  2 word" with dimmed digits
            let out = NSMutableAttributedString()
            for (i, w) in s.components(separatedBy: "\u{1F}").enumerated() {
                if i > 0 { out.append(NSAttributedString(string: "   ", attributes: [.font: font])) }
                out.append(NSAttributedString(string: "\(i + 1) ", attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: font.pointSize * 0.8, weight: .semibold),
                    .foregroundColor: NSColor.secondaryLabelColor, .baselineOffset: font.pointSize * 0.06,
                ]))
                out.append(NSAttributedString(string: w, attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
            }
            return out
        }
        return NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: ghostColor])
    }

    private var hintSize: CGSize {
        guard showHint, kind != .choices else { return .zero }
        let t = ("tab" as NSString).size(withAttributes: [.font: hintFont])
        return CGSize(width: ceil(t.width) + hintFont.pointSize * 0.9, height: ceil(t.height) + 2)
    }

    /// Chooses how much of the text fits and returns the size the panel should take.
    func fit(maxWidth: CGFloat) -> CGSize {
        let extra = (hintSize.width > 0 ? hintSize.width + hintGap : 0) + pad * 2
        shown = text
        if !floating {
            // Drop whole words from the end until it fits; they come back as the caret wraps.
            while attributed(shown).size().width + extra > maxWidth, let cut = shown.lastIndex(of: " "), cut > shown.startIndex {
                shown = String(shown[..<cut])
            }
        }
        let t = attributed(shown).size()
        return CGSize(width: t.width + extra + 1, height: max(lineHeight, hintSize.height) + pad * 1.2)
    }

    override func draw(_ dirty: NSRect) {
        if floating {
            let r = bounds.insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7)
            NSColor.windowBackgroundColor.withAlphaComponent(0.97).setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        let a = attributed(kind == .fix ? "→ " + shown : shown)
        let size = a.size()
        let y = (bounds.height - lineHeight) / 2
        a.draw(at: CGPoint(x: pad, y: y))
        let hs = hintSize
        guard hs.width > 0 else { return }
        // A small key cap, so Tab is discoverable without a tutorial.
        let cap = CGRect(x: pad + size.width + hintGap, y: (bounds.height - hs.height) / 2, width: hs.width, height: hs.height)
        let ink = floating ? NSColor.secondaryLabelColor : ghostColor
        let capPath = NSBezierPath(roundedRect: cap.insetBy(dx: 0.5, dy: 0.5), xRadius: 3.5, yRadius: 3.5)
        ink.withAlphaComponent(ink.alphaComponent * 0.7).setStroke()
        capPath.lineWidth = 1
        capPath.stroke()
        let label = NSAttributedString(string: "tab", attributes: [.font: hintFont, .foregroundColor: ink])
        let ls = label.size()
        label.draw(at: CGPoint(x: cap.midX - ls.width / 2, y: cap.midY - ls.height / 2))
    }
}
