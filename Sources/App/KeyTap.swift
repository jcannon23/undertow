import AppKit
import CoreGraphics

/// Marks events we synthesise so our own tap lets them through untouched.
private let syntheticTag: Int64 = 0x554E_4452  // "UNDR"

/// Session-wide keyboard/mouse tap. Needs Accessibility permission. The callback runs on the
/// main run loop and must answer immediately: the whole system's typing waits on it.
final class KeyTap {
    /// Return true to swallow the key.
    var onKey: ((CGEvent) -> Bool)?
    var onPointer: ((CGEventType) -> Void)?
    private var port: CFMachPort?

    var isRunning: Bool { port.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    @discardableResult
    func start() -> Bool {
        if port != nil { return true }
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .leftMouseUp, .rightMouseDown, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }
        let cb: CGEventTapCallBack = { _, type, event, refcon in
            let me = Unmanaged<KeyTap>.fromOpaque(refcon!).takeUnretainedValue()
            switch type {
            case .tapDisabledByTimeout, .tapDisabledByUserInput:
                if let p = me.port { CGEvent.tapEnable(tap: p, enable: true) }
            case .keyDown:
                if event.getIntegerValueField(.eventSourceUserData) == syntheticTag { break }
                if me.onKey?(event) == true { return nil }
            default:
                me.onPointer?(type)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let p = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: cb, userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        port = p
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, p, 0), .commonModes)
        CGEvent.tapEnable(tap: p, enable: true)
        return true
    }

    func stop() {
        if let port { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
        port = nil
    }
}

/// Types text into whatever has focus by posting Unicode key events: works in native fields,
/// web views and terminals alike, and never touches the clipboard.
enum Typer {
    private static let source = CGEventSource(stateID: .privateState)

    static func type(_ text: String) {
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            var end = min(i + 16, units.count)
            // never split a surrogate pair
            if end < units.count, UTF16.isTrailSurrogate(units[end]) { end -= 1 }
            let chunk = Array(units[i..<end])
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                e.flags = []
                e.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                e.setIntegerValueField(.eventSourceUserData, value: syntheticTag)
                e.post(tap: .cgSessionEventTap)
            }
            i = end
        }
    }

    static func backspace(_ count: Int) {
        for _ in 0..<count {
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: down) else { continue }
                e.flags = []
                e.setIntegerValueField(.eventSourceUserData, value: syntheticTag)
                e.post(tap: .cgSessionEventTap)
            }
        }
    }
}

extension CGEvent {
    /// The characters this key press would insert, ignoring our own modifiers bookkeeping.
    var typedString: String {
        var len = 0
        var buf = [UniChar](repeating: 0, count: 8)
        keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &len, unicodeString: &buf)
        return String(utf16CodeUnits: buf, count: len)
    }
}
