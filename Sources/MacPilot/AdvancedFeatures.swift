import AppKit
import Foundation

// MARK: - Local history

struct CommandHistoryEntry: Codable, Identifiable {
    let id: UUID
    let query: String
    let result: String
    let date: Date
}

@MainActor
final class CommandHistoryStore: ObservableObject {
    static let shared = CommandHistoryStore()
    @Published private(set) var entries: [CommandHistoryEntry] = []
    private let key = "MacPilot.commandHistory.v1"
    private init() { load() }

    func record(query: String, result: String) {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        entries.insert(CommandHistoryEntry(id: UUID(), query: clean, result: result, date: Date()), at: 0)
        entries = Array(entries.prefix(100))
        save()
    }

    func clear() { entries.removeAll(); save() }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([CommandHistoryEntry].self, from: data) else { return }
        entries = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

// MARK: - Timeline / observability

struct TimelineEvent: Codable, Identifiable {
    enum Kind: String, Codable { case appLaunch, appTerminate, displayChange, command, storageScan, deviceChange }
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
    private let key = "MacPilot.timeline.v1"
    private init() { load() }

    func add(_ kind: TimelineEvent.Kind, title: String, detail: String = "") {
        events.insert(.init(id: UUID(), date: Date(), kind: kind, title: title, detail: detail), at: 0)
        events = Array(events.prefix(250))
        save()
    }

    func clear() { events.removeAll(); save() }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([TimelineEvent].self, from: data) else { return }
        events = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(events) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

// MARK: - Storage intelligence

struct StorageItem: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let bytes: Int64
    let category: String
}

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

        Task.detached(priority: .utility) {
            let values = roots.compactMap { path, category -> StorageItem? in
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
                let bytes = Self.directorySize(URL(fileURLWithPath: path), maxEntries: 150_000)
                return StorageItem(name: URL(fileURLWithPath: path).lastPathComponent, path: path, bytes: bytes, category: category)
            }
            await MainActor.run {
                self.items = values.sorted { $0.bytes > $1.bytes }
                self.lastScan = Date()
                self.isScanning = false
                TimelineStore.shared.add(.storageScan, title: "Storage scan completed", detail: "Inspected \(values.count) locations")
            }
        }
    }

    private static func directorySize(_ url: URL, maxEntries: Int) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return 0 }
        var total: Int64 = 0
        var count = 0
        for case let item as URL in enumerator {
            count += 1
            if count > maxEntries { break }
            if let values = try? item.resourceValues(forKeys: keys), values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }
}

// MARK: - Finder power actions

enum FinderPowerService {
    private static func appleScript(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        return error == nil ? result.stringValue : nil
    }

    static func createFile(named name: String) -> String {
        let safe = name.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application \"Finder\"
            set targetFolder to target of front window
            set newFile to make new file at targetFolder with properties {name:\"\(safe)\"}
            return POSIX path of (newFile as alias)
        end tell
        """
        guard let value = appleScript(script) else { return "Couldn't create file in Finder" }
        return "Created \(value)"
    }

    static func createFolder(named name: String) -> String {
        let safe = name.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application \"Finder\"
            set targetFolder to target of front window
            set newFolder to make new folder at targetFolder with properties {name:\"\(safe)\"}
            return POSIX path of (newFolder as alias)
        end tell
        """
        guard let value = appleScript(script) else { return "Couldn't create folder in Finder" }
        return "Created \(value)"
    }

    static func duplicateSelection() -> String {
        let script = """
        tell application \"Finder\"
            set itemsToDuplicate to selection
            if (count of itemsToDuplicate) is 0 then return \"No Finder selection\"
            duplicate itemsToDuplicate to (target of front window)
            return \"Duplicated \" & (count of itemsToDuplicate as text) & \" item(s)\"
        end tell
        """
        return appleScript(script) ?? "Couldn't duplicate Finder selection"
    }

    static func renameSelection(to name: String) -> String {
        let safe = name.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application \"Finder\"
            set itemsToRename to selection
            if (count of itemsToRename) is 0 then return \"No Finder selection\"
            set name of item 1 of itemsToRename to \"\(safe)\"
            return POSIX path of (item 1 of itemsToRename as alias)
        end tell
        """
        return appleScript(script).map { "Renamed to \($0)" } ?? "Couldn't rename Finder selection"
    }
}

// MARK: - Clipboard intelligence

enum ClipboardKind: String { case url, email, phone, currency, code, secret, text }

struct ClipboardInsight {
    let text: String
    let kind: ClipboardKind
    let label: String
    let action: String
}

enum ClipboardIntelligence {
    static func inspect() -> ClipboardInsight? {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = value.lowercased()
        let kind: ClipboardKind
        let label: String
        let action: String
        if lower.range(of: #"^https?://"#, options: .regularExpression) != nil { kind = .url; label = "URL"; action = "Open in browser" }
        else if lower.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil { kind = .email; label = "Email"; action = "Create email" }
        else if lower.range(of: #"^[+()0-9][0-9 ()-]{7,}$"#, options: .regularExpression) != nil { kind = .phone; label = "Phone number"; action = "Call / copy" }
        else if lower.range(of: #"^(₹|\$|€|£)\s?\d"#, options: .regularExpression) != nil { kind = .currency; label = "Currency"; action = "Convert / calculate" }
        else if lower.contains("api_key") || lower.contains("sk-") || lower.range(of: #"(?i)^(ghp_|github_pat_|xox[baprs]-)"#, options: .regularExpression) != nil { kind = .secret; label = "Possible secret"; action = "Do not retain" }
        else if lower.contains("import ") || lower.contains("function ") || lower.contains("#!/") || lower.contains("curl ") { kind = .code; label = "Code / command"; action = "Copy as code" }
        else { kind = .text; label = "Text"; action = "Search / copy" }
        return ClipboardInsight(text: value, kind: kind, label: label, action: action)
    }
}

// MARK: - Audio rules (system-level, no driver required)

struct AudioRule: Codable, Identifiable {
    let id: UUID
    var triggerApp: String
    var volume: Int
    var enabled: Bool
}

@MainActor
final class AudioRulesStore: ObservableObject {
    static let shared = AudioRulesStore()
    @Published var rules: [AudioRule] = []
    private let key = "MacPilot.audioRules.v1"
    private init() { load() }

    func add(triggerApp: String, volume: Int) {
        let clean = triggerApp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        rules.append(.init(id: UUID(), triggerApp: clean, volume: min(max(volume, 0), 100), enabled: true))
        save()
    }

    func remove(at offsets: IndexSet) { rules.remove(atOffsets: offsets); save() }
    func setEnabled(_ rule: AudioRule, enabled: Bool) {
        guard let i = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[i].enabled = enabled
        save()
    }

    func setSystemVolume(_ volume: Int) -> Bool {
        let clamped = min(max(volume, 0), 100)
        let source = "set volume output volume \(clamped)"
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        _ = script.executeAndReturnError(&error)
        return error == nil
    }

    func toggleMute() -> Bool {
        guard let script = NSAppleScript(source: "set volume output muted not (output muted of (get volume settings))") else { return false }
        var error: NSDictionary?
        _ = script.executeAndReturnError(&error)
        return error == nil
    }

    static func outputSummary() -> String {
        guard let script = NSAppleScript(source: "get output volume of (get volume settings)") else { return "Unknown" }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        return error == nil ? "System volume \(result.int32Value)%" : "Unknown"
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key), let decoded = try? JSONDecoder().decode([AudioRule].self, from: data) else { return }
        rules = decoded
    }
    private func save() {
        if let data = try? JSONEncoder().encode(rules) { UserDefaults.standard.set(data, forKey: key) }
    }
}

// MARK: - Automation rules

struct MacPilotAutomation: Codable, Identifiable {
    let id: UUID
    var triggerApp: String
    var onLaunch: Bool
    var onTerminate: Bool
    var action: AutomationAction
    var enabled: Bool
}

enum AutomationAction: Codable, Equatable {
    case setVolume(Int)
    case restoreWorkspace(String)
}

@MainActor
final class AutomationEngine: ObservableObject {
    static let shared = AutomationEngine()
    @Published var rules: [MacPilotAutomation] = []
    private let key = "MacPilot.automation.v1"
    private var observers: [NSObjectProtocol] = []
    private init() { load(); startObservers() }

    func addVolumeRule(app: String, launch: Bool, volume: Int) {
        rules.append(.init(id: UUID(), triggerApp: app, onLaunch: launch, onTerminate: !launch, action: .setVolume(volume), enabled: true))
        save()
    }

    func remove(at offsets: IndexSet) { rules.remove(atOffsets: offsets); save() }

    private func startObservers() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.handle(appName: app.localizedName ?? "", launched: true)
        })
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.handle(appName: app.localizedName ?? "", launched: false)
        })
        observers.append(NSApplication.shared.notificationCenter.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in TimelineStore.shared.add(.displayChange, title: "Display configuration changed", detail: "\(NSScreen.screens.count) screen(s) available") }
        })
    }

    private func handle(appName: String, launched: Bool) {
        TimelineStore.shared.add(launched ? .appLaunch : .appTerminate, title: launched ? "\(appName) launched" : "\(appName) terminated")
        for rule in rules where rule.enabled && rule.triggerApp.localizedCaseInsensitiveContains(appName) && (launched ? rule.onLaunch : rule.onTerminate) {
            switch rule.action {
            case .setVolume(let value):
                _ = AudioRulesStore.shared.setSystemVolume(value)
                TimelineStore.shared.add(.command, title: "Audio rule applied", detail: "\(appName) → volume \(value)%")
            case .restoreWorkspace(let name):
                if launched, let workspace = WorkspaceStore().workspaces.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                    _ = WindowManager.restore(workspace)
                    TimelineStore.shared.add(.command, title: "Workspace rule applied", detail: name)
                }
            }
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key), let decoded = try? JSONDecoder().decode([MacPilotAutomation].self, from: data) else { return }
        rules = decoded
    }
    private func save() {
        if let data = try? JSONEncoder().encode(rules) { UserDefaults.standard.set(data, forKey: key) }
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
    }
}

// MARK: - Control Center window

@MainActor
final class ControlCenterController: NSObject {
    static let shared = ControlCenterController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let root = ControlCenterView()
                .frame(width: 920, height: 660)
            let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 660), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            created.title = "MacPilot Control Center"
            created.titleVisibility = .visible
            created.isReleasedWhenClosed = false
            created.contentView = NSHostingView(rootView: root)
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
    @State private var newFileName = "New File"
    @State private var newFolderName = "New Folder"
    @State private var newRuleApp = "Zoom"
    @State private var newRuleVolume = 20

    var body: some View {
        TabView {
            workspaceTab
                .tabItem { Label("Workspaces", systemImage: "rectangle.3.group") }
            finderTab
                .tabItem { Label("Finder", systemImage: "folder") }
            audioTab
                .tabItem { Label("Audio", systemImage: "speaker.wave.2") }
            storageTab
                .tabItem { Label("Storage", systemImage: "internaldrive") }
            intelligenceTab
                .tabItem { Label("Intelligence", systemImage: "sparkles") }
            timelineTab
                .tabItem { Label("Timeline", systemImage: "clock.arrow.circlepath") }
            automationTab
                .tabItem { Label("Automation", systemImage: "bolt") }
        }
        .padding(18)
    }

    private var workspaceTab: some View {
        Form {
            Section("Workspace engine") {
                Text("Save and restore complete window layouts using the same native Accessibility engine as the command palette.")
                    .foregroundStyle(.secondary)
                Button("Open Workspace Command Palette") { NotificationCenter.default.post(name: .openMacPilotCommandPalette, object: nil) }
            }
            Section("Available commands") {
                Text("Restore Workspace")
                Text("Create Workspace from Current Setup")
                Text("Move Chrome to monitor 2")
                Text("Create workspace called YouTube")
            }
        }
        .formStyle(.grouped)
    }

    private var finderTab: some View {
        Form {
            Section("Create") {
                HStack { TextField("File name", text: $newFileName); Button("New File") { clipboardMessage(FinderPowerService.createFile(named: newFileName)) } }
                HStack { TextField("Folder name", text: $newFolderName); Button("New Folder") { clipboardMessage(FinderPowerService.createFolder(named: newFolderName)) } }
            }
            Section("Selection") {
                Button("Duplicate Selected") { clipboardMessage(FinderPowerService.duplicateSelection()) }
                Button("Copy Selected Path") { clipboardMessage(FinderService.copySelectedPath().map { "Copied \($0)" } ?? "Select an item in Finder") }
                Button("Open Terminal Here") { clipboardMessage(FinderService.openTerminalHere() ? "Terminal opened" : "Couldn't open Terminal") }
            }
        }
        .formStyle(.grouped)
    }

    private var audioTab: some View {
        Form {
            Section("System audio") {
                Text(AudioRulesStore.outputSummary()).foregroundStyle(.secondary)
                HStack {
                    Button("Mute / Unmute") { _ = audio.toggleMute() }
                    Button("30%") { _ = audio.setSystemVolume(30) }
                    Button("60%") { _ = audio.setSystemVolume(60) }
                    Button("100%") { _ = audio.setSystemVolume(100) }
                }
            }
            Section("Rules") {
                HStack {
                    TextField("App", text: $newRuleApp)
                    Stepper("\(newRuleVolume)%", value: $newRuleVolume, in: 0...100, step: 5)
                    Button("Add") { audio.add(triggerApp: newRuleApp, volume: newRuleVolume) }
                }
                ForEach(audio.rules) { rule in
                    HStack {
                        Text(rule.triggerApp)
                        Spacer()
                        Text("→ \(rule.volume)%").foregroundStyle(.secondary)
                        Toggle("", isOn: Binding(get: { rule.enabled }, set: { audio.setEnabled(rule, enabled: $0) })).labelsHidden()
                    }
                }
                .onDelete(perform: audio.remove)
            }
        }
        .formStyle(.grouped)
    }

    private var storageTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Storage intelligence").font(.title2.bold())
                    Text("Explain where disk space is going before deleting anything.").foregroundStyle(.secondary)
                }
                Spacer()
                Button(storage.isScanning ? "Scanning…" : "Scan") { storage.scan() }.disabled(storage.isScanning)
            }
            List(storage.items) { item in
                HStack {
                    Image(systemName: "internaldrive")
                    VStack(alignment: .leading) { Text(item.category).font(.headline); Text(item.path).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)).monospacedDigit()
                }
            }
        }
    }

    private var intelligenceTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Clipboard Intelligence").font(.title2.bold())
                Spacer()
                Button("Inspect Clipboard") { clipboard = ClipboardIntelligence.inspect() }
            }
            if let clipboard {
                VStack(alignment: .leading, spacing: 8) {
                    Label(clipboard.label, systemImage: clipboard.kind == .secret ? "lock.fill" : "sparkles")
                        .font(.headline)
                    Text(clipboard.text).textSelection(.enabled).lineLimit(5)
                    Text(clipboard.action).foregroundStyle(.secondary)
                    if clipboard.kind == .secret { Text("Sensitive content is not persisted by MacPilot.").font(.caption).foregroundStyle(.secondary) }
                }
                .padding(14)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            } else {
                ContentUnavailableView("Nothing inspected", systemImage: "doc.on.clipboard", description: Text("Inspect the current clipboard to classify it locally."))
            }
            Divider()
            HStack {
                Text("Command history").font(.headline)
                Spacer()
                Button("Clear") { history.clear() }
            }
            List(history.entries.prefix(12)) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.query).font(.system(.body, design: .rounded).weight(.medium))
                    Text(entry.result).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var timelineTab: some View {
        VStack(alignment: .leading) {
            HStack {
                VStack(alignment: .leading) { Text("Mac Timeline").font(.title2.bold()); Text("A local record of meaningful system changes.").foregroundStyle(.secondary) }
                Spacer(); Button("Clear") { timeline.clear() }
            }
            List(timeline.events) { event in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: icon(for: event.kind)).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.title).font(.headline)
                        if !event.detail.isEmpty { Text(event.detail).font(.caption).foregroundStyle(.secondary) }
                        Text(event.date, style: .date).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var automationTab: some View {
        Form {
            Section("App-triggered audio rule") {
                Text("When an app launches, MacPilot can change system output volume without installing an audio driver.").foregroundStyle(.secondary)
                HStack { TextField("App", text: $newRuleApp); Stepper("\(newRuleVolume)%", value: $newRuleVolume, in: 0...100, step: 5); Button("Add launch rule") { automation.addVolumeRule(app: newRuleApp, launch: true, volume: newRuleVolume) } }
            }
            Section("Rules") {
                ForEach(automation.rules) { rule in
                    HStack {
                        Image(systemName: "bolt.fill")
                        Text(rule.triggerApp)
                        Spacer()
                        switch rule.action { case .setVolume(let value): Text("Launch → volume \(value)%").foregroundStyle(.secondary); case .restoreWorkspace(let name): Text("Restore \(name)").foregroundStyle(.secondary) }
                    }
                }
                .onDelete(perform: automation.remove)
            }
        }
        .formStyle(.grouped)
    }

    private func clipboardMessage(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        TimelineStore.shared.add(.command, title: value)
    }

    private func icon(for kind: TimelineEvent.Kind) -> String {
        switch kind { case .appLaunch: return "play.circle"; case .appTerminate: return "stop.circle"; case .displayChange: return "display.2"; case .command: return "terminal"; case .storageScan: return "internaldrive"; case .deviceChange: return "externaldrive.connected.to.line.below" }
    }
}

extension Notification.Name {
    static let openMacPilotCommandPalette = Notification.Name("MacPilot.openCommandPalette")
}
