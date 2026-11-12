import AppKit
import SwiftUI

final class Settings: ObservableObject {
    static let shared = Settings()

    @AppStorage("enabled") var enabled = true
    @AppStorage("model") var model = ""  // file name inside modelsDir; empty = automatic
    @AppStorage("length") var length = 1  // 0 short, 1 medium, 2 long
    @AppStorage("showHint") var showHint = true
    @AppStorage("learnStyle") var learnStyle = true
    @AppStorage("typoFix") var typoFix = true
    @AppStorage("wordChoice") var wordChoice = 2  // how hard learned words pull: 0 off, 1 low, 2 medium, 3 high
    @AppStorage("instructions") var instructions = ""  // the user's note about themselves, fed to the model
    @AppStorage("terminals") var terminals = true
    @AppStorage("codeEditors") var codeEditors = false
    @AppStorage("browsers") var browsers = true
    @AppStorage("disabledApps") var disabledAppsRaw = ""  // bundle ids, newline separated
    @AppStorage("wordsAccepted") var wordsAccepted = 0
    @AppStorage("onboarded") var onboarded = false

    static let modelsDir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Undertow/Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    var maxTokens: Int { [8, 16, 28][min(max(length, 0), 2)] }

    var disabledApps: Set<String> {
        get { Set(disabledAppsRaw.split(separator: "\n").map(String.init)) }
        set { disabledAppsRaw = newValue.sorted().joined(separator: "\n") }
    }

    /// Never read these, whatever the user toggles.
    private static let passwordManagers: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.apple.keychainaccess",
        "com.apple.Passwords", "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal", "org.keepassxc.keepassxc",
        "com.apple.loginwindow", "com.apple.SecurityAgent",
    ]
    private static let codeEditorIDs: Set<String> = [
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.apple.dt.Xcode", "dev.zed.Zed",
        "com.sublimetext.4", "com.exafunction.windsurf",
    ]

    @AppStorage("seededOffApps") var seededOffApps = false

    /// Tab moves between cells in a spreadsheet, so those start turned off. Done once: after
    /// that the list is the user's.
    func seedDisabledApps() {
        guard !seededOffApps else { return }
        seededOffApps = true
        disabledApps.formUnion(["com.microsoft.Excel", "com.apple.Numbers"])
    }

    private static let browserIDs = FocusReader.chromium.union([
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "org.mozilla.firefox", "com.kagi.kagimacOS",
    ])

    func allows(_ bundleID: String) -> Bool {
        if Self.passwordManagers.contains(bundleID) || disabledApps.contains(bundleID) { return false }
        if FocusReader.terminals.contains(bundleID) { return terminals }
        if Self.browserIDs.contains(bundleID) { return browsers }
        if Self.codeEditorIDs.contains(bundleID) || bundleID.hasPrefix("com.jetbrains.") { return codeEditors }
        return true
    }

    /// The full installer ships a model inside the app. Move it out to our data folder on first
    /// launch so that small app-only updates never have to carry it (an APFS clone: instant, no
    /// extra disk).
    static func adoptBundledModels() {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Models"),
            let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        for f in files where f.pathExtension == "gguf" {
            let dest = modelsDir.appendingPathComponent(f.lastPathComponent)
            if !FileManager.default.fileExists(atPath: dest.path) { try? FileManager.default.copyItem(at: f, to: dest) }
        }
    }

    /// Model files on disk, largest (best) first.
    static func installedModels() -> [URL] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: modelsDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        // A model the user pointed us at is a link; skip it if the file behind it has gone.
        return files.filter { $0.pathExtension == "gguf" && fm.fileExists(atPath: $0.path) }.sorted { size($0) > size($1) }
    }

    static func size(_ u: URL) -> Int { (try? u.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }

    /// The chosen model, or the largest one that leaves this Mac comfortable headroom.
    func resolvedModel() -> URL? {
        let all = Self.installedModels()
        if let pick = all.first(where: { $0.lastPathComponent == model }) { return pick }
        let ramGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        let budget = Int(ramGB * 0.22 * 1_073_741_824)  // ~3.5 GB on 16 GB, ~5.3 GB on 24 GB
        return all.first { Self.size($0) <= budget } ?? all.last
    }
}
