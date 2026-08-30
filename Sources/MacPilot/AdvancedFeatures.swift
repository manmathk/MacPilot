import AppKit
import Combine
import Foundation

// MARK: - Command history

struct CommandHistoryEntry: Codable, Identifiable, Sendable {
    let id: UUID
    let query: String
    let result: String
    let date: Date
}

@MainActor
final class CommandHistoryStore: ObservableObject {
    static let shared = CommandHistoryStore()
    @Published private(set) var entries: [CommandHistoryEntry] = []
    private let key = "MacPilot.commandHistory.v2"
    private init() { load() }
    func record(query: String, result: String) { let clean = query.trimmingCharacters(in: .whitespacesAndNewlines); guard !clean.isEmpty else { return }; entries.insert(.init(id: UUID(), query: clean, result: result, date: Date()), at: 0); entries = Array(entries.prefix(100)); persist() }
    func clear() { entries.removeAll(); persist() }
    private func load() { guard let data = UserDefaults.standard.data(forKey: key), let decoded = try? JSONDecoder().decode([CommandHistoryEntry].self, from: data) else { return }; entries = decoded }
    private func persist() { if let data = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(data, forKey: key) } }
}

// MARK: - Mac Timeline

struct TimelineEvent: Codable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case appLaunch, appTerminate, displayChange, command, storageScan, deviceChange }
    let id: UUID
    let date: Date
    let kind: Kind
    let title: String
    let detail: String
}

@MainActor
final class TimelineStore: ObservableObject {
    static let shared = TimelineStore()
    @Published private(set) var events: [TimelineEvent] = []
    private let key = "MacPilot.timeline.v2"
    private init() { load() }
    func add(_ kind: TimelineEvent.Kind, title: String, detail: String = "") { events.insert(.init(id: UUID(), date: Date(), kind: kind, title: title, detail: detail), at: 0); events = Array(events.prefix(250)); persist() }
    func clear() { events.removeAll(); persist() }
    private func load() { guard let data = UserDefaults.standard.data(forKey: key), let decoded = try? JSONDecoder().decode([TimelineEvent].self, from: data) else { return }; events = decoded }
    private func persist() { if let data = try? JSONEncoder().encode(events) { UserDefaults.standard.set(data, forKey: key) } }
}

// MARK: - Storage intelligence

struct StorageItem: Identifiable, Sendable { let id = UUID(); let name: String; let path: String; let bytes: Int64; let category: String }

@MainActor
final class StorageIntelligence: ObservableObject {
    @Published private(set) var items: [StorageItem] = []
    @Published private(set) var isScanning = false
    @Published private(set) var lastScan: Date?
    func scan() {
        guard !isScanning else { return }
        isScanning = true
        let roots: [(String, String)] = [
            (NSHomeDirectory() + "/Applications", "Applications"),
            (NSHomeDirectory() + "/Documents", "Documents"),
            (NSHomeDirectory() + "/Downloads", "Downloads"),
            (NSHomeDirectory() + "/Library/Caches", "Caches"),
            (NSHomeDirectory() + "/Library/Developer", "Developer"),
            (NSHomeDirectory() + "/Library/Containers", "Containers"),
            (NSHomeDirectory() + "/.docker", "Docker"),
            (NSHomeDirectory() + "/Library/MobileSync", "iPhone Backups")
        ]
        let items = DispatchWorkItem { [weak self] in
            let values = roots.compactMap { path, category -> StorageItem? in
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
                return StorageItem(name: URL(fileURLWithPath: path).lastPathComponent, path: path, bytes: Self.directorySize(URL(fileURLWithPath: path)), category: category)
            }
            DispatchQueue.main.async {
                self?.items = values.sorted { $0.bytes > $1.bytes }
                self?.lastScan = Date()
                self?.isScanning = false
                TimelineStore.shared.add(.storageScan, title: "Storage scan completed", detail: "Inspected \(values.count) locations")
            }
        }
        DispatchQueue.global(qos: .utility).async(execute: items)
    }
    private nonisolated static func directorySize(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return 0 }
        var total: Int64 = 0; var count = 0
        for case let item as URL in enumerator { count += 1; if count > 150_000 { break }; if let values = try? item.resourceValues(forKeys: keys), values.isRegularFile == true { total += Int64(values.fileSize ?? 0) } }
        return total
    }
}

// MARK: - Finder power actions

enum FinderPowerService {
    private static func run(_ source: String) -> String? { guard let script = NSAppleScript(source: source) else { return nil }; var error: NSDictionary?; let result = script.executeAndReturnError(&error); return error == nil ? result.stringValue : nil }
    static func createFile(named name: String) -> String { let safe = name.replacingOccurrences(of: "\"", with: "\\\""); let script = "tell application \"Finder\" to make new file at (target of front window) with properties {name:\"\(safe)\"}"; return run(script).map { "Created \($0)" } ?? "Couldn't create file in Finder" }
    static func createFolder(named name: String) -> String { let safe = name.replacingOccurrences(of: "\"", with: "\\\""); let script = "tell application \"Finder\" to make new folder at (target of front window) with properties {name:\"\(safe)\"}"; return run(script).map { "Created \($0)" } ?? "Couldn't create folder in Finder" }
    static func duplicateSelection() -> String { let script = "tell application \"Finder\" to if (count of selection) is 0 then return \"No Finder selection\" else duplicate selection to (target of front window)"; return run(script) ?? "Couldn't duplicate Finder selection" }
    static func renameSelection(to name: String) -> String { let safe = name.replacingOccurrences(of: "\"", with: "\\\""); let script = "tell application \"Finder\" to if (count of selection) is 0 then return \"No Finder selection\" else set name of item 1 of selection to \"\(safe)\""; return run(script) ?? "Couldn't rename Finder selection" }
}

// MARK: - Clipboard intelligence

enum ClipboardKind: String, Sendable { case url, email, phone, currency, code, secret, text }
struct ClipboardInsight: Sendable { let text: String; let kind: ClipboardKind; let label: String; let action: String }

enum ClipboardIntelligence {
    static func inspect() -> ClipboardInsight? {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines); let lower = value.lowercased()
        if lower.range(of: #"^https?://"#, options: .regularExpression) != nil { return .init(text: value, kind: .url, label: "URL", action: "Open in browser") }
        if lower.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil { return .init(text: value, kind: .email, label: "Email", action: "Create email") }
        if lower.range(of: #"^[+()0-9][0-9 ()-]{7,}$"#, options: .regularExpression) != nil { return .init(text: value, kind: .phone, label: "Phone number", action: "Call / copy") }
        if lower.range(of: #"^(₹|\$|€|£)\s?\d"#, options: .regularExpression) != nil { return .init(text: value, kind: .currency, label: "Currency", action: "Convert / calculate") }
        if lower.contains("api_key") || lower.contains("sk-") || lower.range(of: #"^(ghp_|github_pat_|xox[baprs]-)"#, options: .regularExpression) != nil { return .init(text: value, kind: .secret, label: "Possible secret", action: "Do not retain") }
        if lower.contains("import ") || lower.contains("function ") || lower.contains("#!/") || lower.contains("curl ") { return .init(text: value, kind: .code, label: "Code / command", action: "Copy as code") }
        return .init(text: value, kind: .text, label: "Text", action: "Search / copy")
    }
}

// MARK: - Audio automation

struct AudioRule: Codable, Identifiable { let id: UUID; var triggerApp: String; var volume: Int; var enabled: Bool }
@MainActor
final class AudioRulesStore: ObservableObject {
    static let shared = AudioRulesStore()
    @Published var rules: [AudioRule] = []
    private let key = "MacPilot.audioRules.v2"
    private init() { load() }
    func add(triggerApp: String, volume: Int) { let clean = triggerApp.trimmingCharacters(in: .whitespacesAndNewlines); guard !clean.isEmpty else { return }; rules.append(.init(id: UUID(), triggerApp: clean, volume: min(max(volume, 0), 100), enabled: true)); save() }
    func remove(at offsets: IndexSet) { rules.remove(atOffsets: offsets); save() }
    func setEnabled(_ rule: AudioRule, enabled: Bool) { guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }; rules[index].enabled = enabled; save() }
    func setSystemVolume(_ volume: Int) -> Bool { guard let script = NSAppleScript(source: "set volume output volume \(min(max(volume, 0), 100))") else { return false }; var error: NSDictionary?; _ = script.executeAndReturnError(&error); return error == nil }
    func toggleMute() -> Bool { guard let script = NSAppleScript(source: "set volume output muted not (output muted of (get volume settings))") else { return false }; var error: NSDictionary?; _ = script.executeAndReturnError(&error); return error == nil }
    static func outputSummary() -> String { guard let script = NSAppleScript(source: "get output volume of (get volume settings)") else { return "Unknown" }; var error: NSDictionary?; let result = script.executeAndReturnError(&error); return error == nil ? "System volume \(result.int32Value)%" : "Unknown" }
    private func load() { guard let data = UserDefaults.standard.data(forKey: key), let decoded = try? JSONDecoder().decode([AudioRule].self, from: data) else { return }; rules = decoded }
    private func save() { if let data = try? JSONEncoder().encode(rules) { UserDefaults.standard.set(data, forKey: key) } }
}

// MARK: - App automation

struct MacPilotAutomation: Codable, Identifiable { let id: UUID; var triggerApp: String; var action: AutomationAction; var enabled: Bool }
enum AutomationAction: Codable, Equatable { case setVolume(Int) }

@MainActor
final class AutomationEngine: ObservableObject {
    static let shared = AutomationEngine()
    @Published var rules: [MacPilotAutomation] = []
    private let key = "MacPilot.automation.v2"
    private var timer: Timer?
    private var knownApps: Set<String> = []
    private init() { load(); knownApps = currentApps(); timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.poll() } }
    func addVolumeRule(app: String, volume: Int) { let clean = app.trimmingCharacters(in: .whitespacesAndNewlines); guard !clean.isEmpty else { return }; rules.append(.init(id: UUID(), triggerApp: clean, action: .setVolume(min(max(volume, 0), 100)), enabled: true)); save() }
    func remove(at offsets: IndexSet) { rules.remove(atOffsets: offsets); save() }
    func stop() { timer?.invalidate(); timer = nil }
    private func currentApps() -> Set<String> { Set(NSWorkspace.shared.runningApplications.compactMap { $0.localizedName }) }
    private func poll() {
        let current = currentApps(); let launched = current.subtracting(knownApps); let terminated = knownApps.subtracting(current)
        for app in launched { TimelineStore.shared.add(.appLaunch, title: "\(app) launched"); applyRules(appName: app) }
        for app in terminated { TimelineStore.shared.add(.appTerminate, title: "\(app) terminated") }
        knownApps = current
    }
    private func applyRules(appName: String) { for rule in rules where rule.enabled && rule.triggerApp.localizedCaseInsensitiveContains(appName) { if case .setVolume(let value) = rule.action { _ = AudioRulesStore.shared.setSystemVolume(value); TimelineStore.shared.add(.command, title: "Audio rule applied", detail: "\(appName) → \(value)%") } } }
    private func load() { guard let data = UserDefaults.standard.data(forKey: key), let decoded = try? JSONDecoder().decode([MacPilotAutomation].self, from: data) else { return }; rules = decoded }
    private func save() { if let data = try? JSONEncoder().encode(rules) { UserDefaults.standard.set(data, forKey: key) } }
}

// MARK: - Control Center

@MainActor
final class ControlCenterController: NSObject {
    static let shared = ControlCenterController()
    private var window: NSWindow?
    func show() {
        if window == nil {
            let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 660), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            created.title = "MacPilot Control Center"
            created.isReleasedWhenClosed = false
            created.contentView = NSHostingView(rootView: ControlCenterView().frame(width: 920, height: 660))
            created.center()
            window = created
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct ControlCenterView: View {
    @StateObject private var storage = StorageIntelligence()
    @ObservedObject private var history = CommandHistoryStore.shared
    @ObservedObject private var timeline = TimelineStore.shared
    @ObservedObject private var audio = AudioRulesStore.shared
    @ObservedObject private var automation = AutomationEngine.shared
    @State private var clipboard: ClipboardInsight?
    @State private var fileName = "New File"
    @State private var folderName = "New Folder"
    @State private var renameName = "Renamed Item"
    @State private var ruleApp = "Zoom"
    @State private var ruleVolume = 20

    var body: some View {
        TabView {
            workspaceTab.tabItem { Label("Workspaces", systemImage: "rectangle.3.group") }
            finderTab.tabItem { Label("Finder", systemImage: "folder") }
            audioTab.tabItem { Label("Audio", systemImage: "speaker.wave.2") }
            storageTab.tabItem { Label("Storage", systemImage: "internaldrive") }
            intelligenceTab.tabItem { Label("Intelligence", systemImage: "sparkles") }
            timelineTab.tabItem { Label("Timeline", systemImage: "clock.arrow.circlepath") }
            automationTab.tabItem { Label("Automation", systemImage: "bolt") }
        }
        .padding(18)
    }
    private var workspaceTab: some View { Form { Section("Workspace engine") { Text("Capture and restore application windows, sizes and positions using Accessibility APIs.").foregroundStyle(.secondary); Button("Open command palette") { NotificationCenter.default.post(name: .openMacPilotCommandPalette, object: nil) }; Button("Accessibility permission") { WindowManager.requestAccessibility() } }; Section("Examples") { Text("Restore Coding Workspace"); Text("Create workspace called YouTube"); Text("Move Chrome to monitor 2") } }.formStyle(.grouped) }
    private var finderTab: some View { Form { Section("Create") { HStack { TextField("File name", text: $fileName); Button("New File") { record(FinderPowerService.createFile(named: fileName)) } }; HStack { TextField("Folder name", text: $folderName); Button("New Folder") { record(FinderPowerService.createFolder(named: folderName)) } } }; Section("Selection") { Button("Duplicate Selected") { record(FinderPowerService.duplicateSelection()) }; HStack { TextField("Rename selected", text: $renameName); Button("Rename") { record(FinderPowerService.renameSelection(to: renameName)) } }; Button("Copy Selected Path") { record(FinderService.copySelectedPath().map { "Copied \($0)" } ?? "Select an item in Finder") }; Button("Open Terminal Here") { record(FinderService.openTerminalHere() ? "Terminal opened" : "Couldn't open Terminal") } } }.formStyle(.grouped) }
    private var audioTab: some View { Form { Section("System audio") { Text(AudioRulesStore.outputSummary()).foregroundStyle(.secondary); HStack { Button("Mute / Unmute") { _ = audio.toggleMute() }; Button("30%") { _ = audio.setSystemVolume(30) }; Button("60%") { _ = audio.setSystemVolume(60) }; Button("100%") { _ = audio.setSystemVolume(100) } } }; Section("Rules") { HStack { TextField("App", text: $ruleApp); Stepper("\(ruleVolume)%", value: $ruleVolume, in: 0...100, step: 5); Button("Add") { audio.add(triggerApp: ruleApp, volume: ruleVolume) } }; ForEach(audio.rules) { rule in HStack { Text(rule.triggerApp); Spacer(); Text("→ \(rule.volume)%").foregroundStyle(.secondary); Toggle("", isOn: Binding(get: { rule.enabled }, set: { audio.setEnabled(rule, enabled: $0) })).labelsHidden() } }.onDelete(perform: audio.remove) } }.formStyle(.grouped) }
    private var storageTab: some View { VStack(alignment: .leading, spacing: 14) { HStack { VStack(alignment: .leading) { Text("Storage intelligence").font(.title2.bold()); Text("Review large areas before taking cleanup action.").foregroundStyle(.secondary) }; Spacer(); Button(storage.isScanning ? "Scanning…" : "Scan") { storage.scan() }.disabled(storage.isScanning) }; List(storage.items) { item in HStack { Image(systemName: "internaldrive"); VStack(alignment: .leading) { Text(item.category).font(.headline); Text(item.path).font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)).monospacedDigit() } } } }
    private var intelligenceTab: some View { VStack(alignment: .leading, spacing: 14) { HStack { Text("Clipboard Intelligence").font(.title2.bold()); Spacer(); Button("Inspect clipboard") { clipboard = ClipboardIntelligence.inspect() } }; if let clipboard { VStack(alignment: .leading, spacing: 8) { Label(clipboard.label, systemImage: clipboard.kind == .secret ? "lock.fill" : "sparkles").font(.headline); Text(clipboard.text).textSelection(.enabled).lineLimit(6); Text(clipboard.action).foregroundStyle(.secondary); if clipboard.kind == .secret { Text("Sensitive clipboard values are not stored by MacPilot.").font(.caption).foregroundStyle(.secondary) } }.padding(14).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12)) } else { ContentUnavailableView("Nothing inspected", systemImage: "doc.on.clipboard", description: Text("Classify the current clipboard locally.")) }; Divider(); HStack { Text("Recent commands").font(.headline); Spacer(); Button("Clear") { history.clear() } }; List(history.entries.prefix(15)) { entry in VStack(alignment: .leading, spacing: 3) { Text(entry.query).font(.system(.body, design: .rounded).weight(.medium)); Text(entry.result).font(.caption).foregroundStyle(.secondary) } } } }
    private var timelineTab: some View { VStack(alignment: .leading) { HStack { VStack(alignment: .leading) { Text("Mac Timeline").font(.title2.bold()); Text("Local visibility into app and display changes.").foregroundStyle(.secondary) }; Spacer(); Button("Clear") { timeline.clear() } }; List(timeline.events) { event in HStack(alignment: .top, spacing: 12) { Image(systemName: icon(for: event.kind)).frame(width: 22); VStack(alignment: .leading, spacing: 3) { Text(event.title); if !event.detail.isEmpty { Text(event.detail).font(.caption).foregroundStyle(.secondary) }; Text(event.date, style: .date).font(.caption2).foregroundStyle(.tertiary) } } } } }
    private var automationTab: some View { Form { Section("Launch automation") { Text("Apply a system-volume rule automatically when an app appears.").foregroundStyle(.secondary); HStack { TextField("App", text: $ruleApp); Stepper("\(ruleVolume)%", value: $ruleVolume, in: 0...100, step: 5); Button("Add rule") { automation.addVolumeRule(app: ruleApp, volume: ruleVolume) } } }; Section("Rules") { ForEach(automation.rules) { rule in HStack { Image(systemName: "bolt.fill"); Text(rule.triggerApp); Spacer(); if case .setVolume(let value) = rule.action { Text("Launch → \(value)%").foregroundStyle(.secondary) } } }.onDelete(perform: automation.remove) } }.formStyle(.grouped) }
    private func record(_ result: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result, forType: .string); TimelineStore.shared.add(.command, title: result) }
    private func icon(for kind: TimelineEvent.Kind) -> String { switch kind { case .appLaunch: return "play.circle"; case .appTerminate: return "stop.circle"; case .displayChange: return "display.2"; case .command: return "terminal"; case .storageScan: return "internaldrive"; case .deviceChange: return "externaldrive.connected.to.line.below" } }
}

extension Notification.Name { static let openMacPilotCommandPalette = Notification.Name("MacPilot.openCommandPalette") }
