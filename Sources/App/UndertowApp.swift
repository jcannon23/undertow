import AppKit
import ApplicationServices
import ServiceManagement
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
        case .missing: info = "No model installed"
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
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
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

    var body: some View {
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
            Section("Try it") {
                TextEditor(text: $scratch)
                    .font(.body)
                    .frame(height: 70)
                    .overlay(alignment: .topLeading) {
                        if scratch.isEmpty {
                            Text("Type a sentence here…").foregroundStyle(.tertiary).padding(.leading, 5).allowsHitTesting(false)
                        }
                    }
                LabeledContent("Next word") { Keys(["tab"]) }
                LabeledContent("Whole suggestion") { Keys(["shift", "tab"]) }
                LabeledContent("Other words that fit") { Keys(["option", "tab"]) }
                LabeledContent("Dismiss") { Keys(["esc"]) }
            }
            Section("Model") {
                Picker("Model", selection: settings.$model) {
                    Text("Automatic").tag("")
                    ForEach(Settings.installedModels(), id: \.lastPathComponent) { u in
                        Text("\(u.deletingPathExtension().lastPathComponent)  ·  \(ByteCountFormatter.string(fromByteCount: Int64(Settings.size(u)), countStyle: .file))")
                            .tag(u.lastPathComponent)
                    }
                }
                .onChange(of: settings.model) { _, _ in coordinator.loadModel() }
                LabeledContent("Status") { Text(modelStatus).foregroundStyle(.secondary) }
                Text("Runs entirely on this Mac. The model is released from memory after 20 idle minutes or when memory runs short.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Writing help") {
                Toggle("Offer fixes for typos", isOn: settings.$typoFix)
                Toggle("Learn my writing style", isOn: settings.$learnStyle)
                    .onChange(of: settings.learnStyle) { _, _ in coordinator.refreshLM() }
                LabeledContent("Learned so far") {
                    HStack {
                        Text(learnedSummary).foregroundStyle(.secondary)
                        Button("Erase") { coordinator.style.erase(); coordinator.refreshLM(); learned = 0 }.disabled(learned == 0 && coordinator.style.feedbackTotals.shown == 0)
                    }
                }
                Text("Undertow keeps passages you type, your names and jargon, the words you tend to follow with, and which suggestions you take or type past. All of it stays encrypted on this Mac. Anything that looks like a password, key or card number is never stored.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Where") {
                Toggle("Terminals", isOn: settings.$terminals)
                Toggle("Code editors", isOn: settings.$codeEditors)
                ForEach(settings.disabledApps.sorted(), id: \.self) { id in
                    LabeledContent(appName(id)) {
                        Button("Turn On") { var s = settings.disabledApps; s.remove(id); settings.disabledApps = s }
                    }
                }
                Text("Password fields and password managers are always ignored. Turn Undertow off for any app from its menu bar icon.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 640)
        .onAppear { learned = coordinator.style.count; settings.onboarded = true }
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
        case .missing: return "No model in the Models folder"
        case .loading: return "Loading…"
        case .ready: return "Ready"
        case .failed: return "Failed to load"
        case .asleep: return "Resting"
        }
    }

    private func appName(_ id: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { FileManager.default.displayName(atPath: $0.path) } ?? id
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
