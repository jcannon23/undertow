import Foundation

/// Diagnostic trace, off unless `defaults write app.undertow.Undertow debugLog -bool YES`.
/// It records typed text, so it is strictly a development aid.
enum Log {
    static let on = UserDefaults.standard.bool(forKey: "debugLog")
    private static let handle: FileHandle? = {
        let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Undertow.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try? FileHandle(forWritingTo: url)
    }()
    private static let t0 = Date()

    static func d(_ msg: @autoclosure () -> String) {
        guard on else { return }
        let line = String(format: "%8.3f ", Date().timeIntervalSince(t0)) + msg().replacingOccurrences(of: "\n", with: "⏎") + "\n"
        handle?.write(line.data(using: .utf8)!)
    }
}
