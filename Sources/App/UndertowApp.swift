import UniformTypeIdentifiers
import AppKit
import ApplicationServices
import ServiceManagement
import Sparkle
import SwiftUI

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let coordinator = Coordinator()
    private let settings = Settings.shared
    private var status: NSStatusItem!
    private var window: NSWindow?
    private var trustTimer: Timer?
    /// Sparkle: checks the release feed daily and installs signed updates.
    private let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    func applicationDidFinishLaunching(_ note: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        status.menu = menu
        updateIcon()
        coordinator.start()
        if !coordinator.trusted || !settings.onboarded { showWindow() }
        // Permission is granted in System Settings, outside our process: poll until it lands.
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !self.coordinator.trusted || !self.coordinator.tap.isRunning { self.coordinator.refreshTrust() }
            self.updateIcon()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    private func updateIcon() {
        let on = settings.enabled && coordinator.trusted
        let img = NSImage(named: "MenuBarIcon") ?? NSImage(systemSymbolName: "character.cursor.ibeam", accessibilityDescription: "Undertow")
        img?.size = NSSize(width: 18, height: 18)
        img?.accessibilityDescription = "Undertow"
        img?.isTemplate = true
        status.button?.image = img
        status.button?.appearsDisabled = !on
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let front = NSWorkspace.shared.frontmostApplication
        let toggle = NSMenuItem(title: "Suggestions", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.state = settings.enabled ? .on : .off
        toggle.target = self
        menu.addItem(toggle)
        if let id = front?.bundleIdentifier, id != Bundle.main.bundleIdentifier, let name = front?.localizedName {
            let off = settings.disabledApps.contains(id)
            let item = NSMenuItem(title: off ? "Turn On in \(name)" : "Turn Off in \(name)", action: #selector(toggleApp(_:)), keyEquivalent: "")
            item.representedObject = id
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let info: String
        switch coordinator.modelState {
        case .missing:
            let p = coordinator.downloader.progress.values.first
            info = p.map { "Downloading model… \(Int($0 * 100))%" } ?? "No model installed"
        case .loading: info = "Loading model…"
        case .ready(let n): info = n.replacingOccurrences(of: ".gguf", with: "")
        case .failed(let n): info = "Could not load \(n)"
        case .asleep: info = "Model resting (wakes when you type)"
        }
        menu.addItem(disabled(coordinator.trusted ? info : "Needs Accessibility permission"))
        menu.addItem(disabled("\(settings.wordsAccepted.formatted()) words completed"))
        menu.addItem(.separator())
        let prefs = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)
        let update = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        update.target = updater
        menu.addItem(update)
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        menu.addItem(disabled("Version \(v)"))
        menu.addItem(NSMenuItem(title: "Quit Undertow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    @objc private func toggleEnabled() { settings.enabled.toggle(); updateIcon() }
    @objc private func openSettings() { showWindow() }
    @objc private func toggleApp(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        var set = settings.disabledApps
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        settings.disabledApps = set
    }

    private func showWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
                styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Undertow"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: SettingsView(coordinator: coordinator, settings: settings))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Settings window

struct SettingsView: View {
    @ObservedObject var coordinator: Coordinator
    @ObservedObject var settings: Settings
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var learned = 0
    @State private var scratch = ""

    @State private var custom: [URL] = []
    @State private var addError: String?

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            modelTab.tabItem { Label("Model", systemImage: "cpu") }
            writing.tabItem { Label("Writing", systemImage: "pencil.line") }
            apps.tabItem { Label("Apps", systemImage: "macwindow") }
        }
        .padding(.top, 8)
        .frame(width: 520, height: 520)
        .onAppear { learned = coordinator.style.count; settings.onboarded = true; refreshCustom() }
    }

    private var general: some View {
        Form {
            if !coordinator.trusted { permission }
            if systemPredictionOn { systemPrediction }
            Section {
                Toggle("Show suggestions as I type", isOn: settings.$enabled)
                Picker("Suggestion length", selection: settings.$length) {
                    Text("A few words").tag(0)
                    Text("A phrase").tag(1)
                    Text("To the end of the sentence").tag(2)
                }
                Toggle("Show the tab key hint", isOn: settings.$showHint)
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
            Section("Keys") {
                LabeledContent("Next word") { Keys(["tab"]) }
                LabeledContent("Whole suggestion") { Keys(["shift", "tab"]) }
                LabeledContent("Other words that fit") { Keys(["option", "tab"]) }
                LabeledContent("Dismiss") { Keys(["esc"]) }
            }
            Section("Try it") {
                TextEditor(text: $scratch)
                    .font(.body)
                    .frame(height: 70)
                    .overlay(alignment: .topLeading) {
                        if scratch.isEmpty {
                            Text("Type a sentence here…").foregroundStyle(.tertiary).padding(.leading, 5).allowsHitTesting(false)
                        }
                    }
            }
        }
        .formStyle(.grouped)
    }

    private var modelTab: some View {
        Form {
            Section {
                ForEach(ModelOption.catalog) { m in ModelRow(model: m, coordinator: coordinator, downloader: coordinator.downloader, settings: settings) }
            } header: {
                Text("Recommended")
            } footer: {
                Text("Undertow uses the largest installed model that fits comfortably unless you choose one.")
            }
            Section {
                ForEach(custom, id: \.self) { url in
                    let name = url.lastPathComponent
                    LabeledContent {
                        HStack {
                            if coordinator.modelState == .ready(name) {
                                Label("In use", systemImage: "checkmark").foregroundStyle(.secondary)
                            } else {
                                Button("Use") { settings.model = name; coordinator.loadModel() }
                            }
                            Button("Remove") { removeCustom(url) }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(url.deletingPathExtension().lastPathComponent)
                            Text(String(format: "%.1f GB", Double(Settings.size(url)) / 1e9)).font(.footnote).foregroundStyle(.secondary)
                            if coordinator.modelState == .failed(name) {
                                Text("Undertow could not load this file.").font(.footnote).foregroundStyle(.red)
                            }
                        }
                    }
                }
                Button("Add Model File…") { addModel() }
                if let addError { Text(addError).font(.footnote).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            } header: {
                Text("Your own")
            } footer: {
                Text("Point Undertow at a model you downloaded yourself. It must be a GGUF file; Gemma models work best. The file stays where it is, so keep it there.")
            }
            Section {
                LabeledContent("Status") { Text(modelStatus).foregroundStyle(.secondary) }
            } footer: {
                Text("Models run entirely on this Mac and are released from memory after 20 idle minutes or when memory runs short.")
            }
        }
        .formStyle(.grouped)
    }

    private var writing: some View {
        Form {
            Section {
                Toggle("Offer fixes for typos", isOn: settings.$typoFix)
            }
            Section {
                Toggle("Learn my writing style", isOn: settings.$learnStyle)
                    .onChange(of: settings.learnStyle) { _, _ in coordinator.refreshLM() }
                LabeledContent("Learned so far") { Text(learnedSummary).foregroundStyle(.secondary) }
                Button("Erase What Undertow Learned") { coordinator.style.erase(); coordinator.refreshLM(); learned = 0 }
                    .disabled(learned == 0 && coordinator.style.feedbackTotals.shown == 0)
            } header: {
                Text("Your style")
            } footer: {
                Text("Undertow keeps passages you type, your names and jargon, the words you tend to follow with, and which suggestions you take or type past. All of it stays encrypted on this Mac. Anything that looks like a password, key or card number is never stored.")
            }
        }
        .formStyle(.grouped)
    }

    private var apps: some View {
        Form {
            Section("Kinds of app") {
                Toggle("Terminals", isOn: settings.$terminals)
                Toggle("Code editors", isOn: settings.$codeEditors)
            }
            Section {
                if settings.disabledApps.isEmpty { Text("None").foregroundStyle(.secondary) }
                ForEach(settings.disabledApps.sorted(), id: \.self) { id in
                    LabeledContent {
                        Button("Turn On") { var s = settings.disabledApps; s.remove(id); settings.disabledApps = s }
                    } label: {
                        HStack(spacing: 8) {
                            Image(nsImage: appIcon(id)).resizable().frame(width: 20, height: 20)
                            Text(appName(id))
                        }
                    }
                }
            } header: {
                Text("Turned off in")
            } footer: {
                Text("To turn Undertow off in an app, switch to that app and choose Turn Off from the menu bar icon. Excel and Numbers start turned off, because Tab moves between cells there. Password fields and password managers are always ignored.")
            }
        }
        .formStyle(.grouped)
    }

    /// Model files in the Models folder that are not ones Undertow offers itself.
    private func refreshCustom() {
        let known = Set(ModelOption.catalog.map(\.file))
        custom = Settings.installedModels().filter { !known.contains($0.lastPathComponent) }
    }

    /// Links the chosen file into the Models folder, so a multi-gigabyte model is not copied.
    private func addModel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "gguf") ?? .data]
        panel.message = "Choose a GGUF model file"
        guard panel.runModal() == .OK, let src = panel.url else { return }
        addError = nil
        let ram = ProcessInfo.processInfo.physicalMemory
        guard Settings.size(src) <= Int(ram / 2) else {
            addError = String(format: "That model is %.1f GB, too large for this Mac's %d GB of memory. Choose one under %d GB.",
                Double(Settings.size(src)) / 1e9, Int(ram >> 30), Int(ram >> 31))
            return
        }
        let dest = Settings.modelsDir.appendingPathComponent(src.lastPathComponent)
        let fm = FileManager.default
        if src.standardizedFileURL != dest.standardizedFileURL {
            if (try? dest.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { try? fm.removeItem(at: dest) }
            guard !fm.fileExists(atPath: dest.path) else { addError = "A model with that name is already installed."; return }
            do { try fm.createSymbolicLink(at: dest, withDestinationURL: src) } catch { addError = error.localizedDescription; return }
        }
        settings.model = dest.lastPathComponent
        coordinator.loadModel()
        refreshCustom()
    }

    /// Forgets a model the user added. Only the link goes; a real file is left for them to delete.
    private func removeCustom(_ url: URL) {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            try? FileManager.default.removeItem(at: url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        if settings.model == url.lastPathComponent { settings.model = ""; coordinator.loadModel() }
        refreshCustom()
    }

    private var permission: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Undertow needs Accessibility permission", systemImage: "hand.raised.fill").font(.headline)
                Text("It reads the text field you are typing in and draws suggestions beside your cursor. Nothing leaves this Mac.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Open Accessibility Settings…") {
                    AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.vertical, 4)
        }
    }

    /// macOS has its own inline predictions in native text views; both at once draw double grey text.
    private var systemPredictionOn: Bool {
        (UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["NSAutomaticInlinePredictionEnabled"] as? Bool) != false
    }

    private var systemPrediction: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Turn off the Mac's own inline predictions", systemImage: "text.cursor").font(.headline)
                Text("macOS also shows grey predictions in apps like Notes and Mail, and they overlap Undertow's. In Keyboard settings, click Edit… next to Input Sources and switch off “Show inline predictive text”.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Open Keyboard Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var learnedSummary: String {
        let f = coordinator.style.feedbackTotals
        var parts = ["\(learned) passages", "\(coordinator.style.vocabularyCount) personal words"]
        if f.shown > 0 { parts.append("\(Int(100 * Double(f.taken) / Double(f.shown)))% of \(f.shown) suggestions taken") }
        return parts.joined(separator: " · ")
    }

    private var modelStatus: String {
        switch coordinator.modelState {
        case .missing: return "Download a model to begin"
        case .loading: return "Loading…"
        case .ready: return "Ready"
        case .failed: return "Failed to load"
        case .asleep: return "Resting"
        }
    }

    private func appIcon(_ id: String) -> NSImage {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSWorkspace.shared.icon(for: .application)
    }

    private func appName(_ id: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { FileManager.default.displayName(atPath: $0.path) }
            ?? id.split(separator: ".").last.map(String.init) ?? id  // not installed here: "com.apple.Numbers" reads as "Numbers"
    }
}

/// One model: download it, watch it arrive, or choose it.
private struct ModelRow: View {
    let model: ModelOption
    @ObservedObject var coordinator: Coordinator
    @ObservedObject var downloader: ModelDownloader
    @ObservedObject var settings: Settings

    private var installed: Bool { FileManager.default.fileExists(atPath: Settings.modelsDir.appendingPathComponent(model.file).path) }

    var body: some View {
        LabeledContent {
            if let p = downloader.progress[model.file] {
                HStack {
                    ProgressView(value: p).frame(width: 90)
                    Text("\(Int(p * 100))%").monospacedDigit().foregroundStyle(.secondary)
                    Button("Cancel") { downloader.cancel(model.file) }
                }
            } else if installed {
                let active = coordinator.modelState == .ready(model.file)
                if active {
                    Label("In use", systemImage: "checkmark").foregroundStyle(.secondary)
                } else {
                    Button("Use") { settings.model = model.file; coordinator.loadModel() }
                }
            } else {
                Button("Download \(String(format: "%.1f", model.approxGB)) GB") { downloader.start(model) }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title)
                Text(model.note).font(.footnote).foregroundStyle(.secondary)
                if let why = downloader.failures[model.file] {
                    Text("Download failed: \(why)").font(.footnote).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct Keys: View {
    var names: [String]
    init(_ n: [String]) { names = n }
    var body: some View {
        HStack(spacing: 4) {
            ForEach(names, id: \.self) { n in
                Text(n).font(.system(size: 11, weight: .medium)).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            }
        }
    }
}
