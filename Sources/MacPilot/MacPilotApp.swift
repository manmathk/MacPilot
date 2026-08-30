import AppKit
import SwiftUI

@main
struct MacPilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .frame(width: 560, height: 460)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panelController: CommandPanelController!
    private var globalMonitor: Any?
    private var localMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        panelController = CommandPanelController()
        _ = AutomationEngine.shared
        setupMenuBar()
        installHotKey()
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "scope", accessibilityDescription: "MacPilot")
        let menu = NSMenu()
        menu.addItem(item("Open MacPilot", #selector(togglePanel)))
        menu.addItem(item("Control Center…", #selector(openControlCenter)))
        menu.addItem(item("Save Workspace…", #selector(saveWorkspace)))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings)))
        menu.addItem(item("Quit MacPilot", #selector(quit), key: "q"))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func installHotKey() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains([.command, .shift]), event.keyCode == 49 else { return }
            Task { @MainActor [weak self] in self?.togglePanel() }
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handler(event)
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            return flags.contains([.command, .shift]) && event.keyCode == 49 ? nil : event
        }
    }

    @objc private func togglePanel() { panelController.toggle() }
    @objc private func openControlCenter() { ControlCenterController.shared.show() }
    @objc private func saveWorkspace() { panelController.presentSaveWorkspace() }
    @objc private func openSettings() { panelController.openSettings() }
    @objc private func quit() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        panelController.teardown()
        AutomationEngine.shared.stop()
    }
}

@MainActor
final class CommandPanelController: NSObject {
    private let panel: NSPanel
    private let model: CommandModel

    override init() {
        model = CommandModel()
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.contentView = NSHostingView(rootView: CommandPaletteView(model: model))
    }

    func toggle() {
        if panel.isVisible { panel.orderOut(nil) } else { show() }
    }

    func show() {
        model.beginSession()
        let target = NSScreen.main ?? NSScreen.screens.first
        if let target {
            let frame = target.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2 + 80))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func presentSaveWorkspace() {
        show()
        model.query = "Create workspace called "
    }

    func openSettings() { SettingsWindowController.shared.show() }

    func teardown() {
        panel.orderOut(nil)
    }
}

@MainActor
final class SettingsWindowController: NSObject {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let created = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            created.title = "MacPilot Settings"
            created.contentView = NSHostingView(rootView: SettingsView().frame(width: 560, height: 460))
            created.isReleasedWhenClosed = false
            created.center()
            window = created
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class CommandModel: ObservableObject {
    struct Command: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String
        let icon: String
        let category: String
        let action: @MainActor () -> Void
    }

    @Published var query = ""
    @Published var message: String?
    @Published var isBusy = false
    @Published var lastStorage: StorageService.VolumeInfo?
    @Published var workspaceCount = 0

    private let workspaceStore = WorkspaceStore()
    private(set) var commands: [Command] = []

    init() {
        commands = [
            Command(title: "Restore Workspace", subtitle: "Restore a saved window arrangement", icon: "rectangle.3.group", category: "Workspaces") { [weak self] in self?.restoreWorkspace() },
            Command(title: "Create Workspace from Current Setup", subtitle: "Capture apps, windows, sizes and positions", icon: "square.and.arrow.down", category: "Workspaces") { [weak self] in self?.saveWorkspace() },
            Command(title: "Open Terminal Here", subtitle: "Use the frontmost Finder folder", icon: "terminal", category: "Finder") { [weak self] in self?.openTerminalHere() },
            Command(title: "Copy Selected File Path", subtitle: "Copy the selected Finder item path", icon: "link", category: "Finder") { [weak self] in self?.copyPath() },
            Command(title: "New Finder File", subtitle: "Create a file in the current Finder folder", icon: "doc.badge.plus", category: "Finder") { [weak self] in self?.message = FinderPowerService.createFile(named: "New File") },
            Command(title: "Show Storage", subtitle: "Inspect disk capacity and usage", icon: "internaldrive", category: "System") { [weak self] in self?.showStorage() },
            Command(title: "Inspect Clipboard", subtitle: "Classify the current clipboard locally", icon: "doc.on.clipboard", category: "Intelligence") { [weak self] in self?.inspectClipboard() },
            Command(title: "Audio Controls", subtitle: "Mute or change system output volume", icon: "speaker.wave.2", category: "Audio") { [weak self] in self?.message = AudioRulesStore.outputSummary() },
            Command(title: "Control Center", subtitle: "Open every MacPilot module", icon: "square.grid.2x2", category: "System") { [weak self] in self?.openControlCenter() },
            Command(title: "Open Settings", subtitle: "Configure MacPilot", icon: "gearshape", category: "System") { [weak self] in self?.openSettings() }
        ]
    }

    var filtered: [Command] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return Array(commands.prefix(10)) }
        let terms = clean.lowercased().split(separator: " ")
        return commands.filter { command in
            let haystack = "\(command.title) \(command.subtitle) \(command.category)".lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }
    }

    var parsedIntent: IntentParser.Intent { IntentParser.parse(query) }

    func beginSession() {
        query = ""
        message = nil
        isBusy = false
        workspaceCount = workspaceStore.workspaces.count
    }

    func executeFirst() {
        switch parsedIntent {
        case .restore(let name): restoreWorkspace(name: name)
        case .save(let name): saveWorkspace(name: name)
        case .moveApp(let app, let monitor): message = WindowManager.moveApp(named: app, toMonitor: monitor)
        case .terminal: openTerminalHere()
        case .copyPath: copyPath()
        case .storage: showStorage()
        case .settings: openSettings()
        case .accessibility: WindowManager.requestAccessibility(); message = "Accessibility request sent"
        case .unknown: filtered.first?.action()
        }
        if let result = message, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            CommandHistoryStore.shared.record(query: query, result: result)
            TimelineStore.shared.add(.command, title: query, detail: result)
        }
    }

    private func restoreWorkspace(name: String? = nil) {
        guard let workspace = workspaceStore.workspaces.first(where: { name == nil || $0.name.caseInsensitiveCompare(name!) == .orderedSame }) ?? workspaceStore.workspaces.first else { message = "No saved workspaces yet"; return }
        guard WindowManager.isAccessibilityTrusted else { message = "Accessibility permission is required to restore windows"; WindowManager.requestAccessibility(); return }
        let result = workspaceStore.restore(workspace)
        message = result.offscreen > 0 ? "Restored \(result.restored); \(result.offscreen) moved back on-screen" : "Restored \(result.restored) windows"
        isBusy = false
    }

    private func saveWorkspace(name: String? = nil) {
        let workspaceName = (name?.isEmpty == false ? name! : "Workspace \(workspaceStore.workspaces.count + 1)").trimmingCharacters(in: .whitespaces)
        guard WindowManager.isAccessibilityTrusted else { message = "Accessibility permission is required to capture windows"; WindowManager.requestAccessibility(); return }
        let snapshot = workspaceStore.saveCurrent(named: workspaceName)
        workspaceCount = workspaceStore.workspaces.count
        message = snapshot.windows.isEmpty ? "Saved, but no accessible windows were captured" : "Saved \(snapshot.windows.count) windows as \(workspaceName)"
    }

    private func openTerminalHere() { message = FinderService.openTerminalHere() ? "Terminal opened in Finder's current folder" : "Couldn't read the frontmost Finder folder" }
    private func copyPath() { message = FinderService.copySelectedPath().map { "Copied \($0)" } ?? "Select a file or folder in Finder first" }
    private func showStorage() { lastStorage = StorageService.volumeInfo(); guard let storage = lastStorage else { message = "Storage information unavailable"; return }; message = "\(ByteCountFormatter.string(fromByteCount: storage.free, countStyle: .file)) free of \(ByteCountFormatter.string(fromByteCount: storage.total, countStyle: .file))" }
    private func inspectClipboard() { message = ClipboardIntelligence.inspect().map { "\($0.label): \($0.action)" } ?? "Clipboard is empty" }
    private func openControlCenter() { ControlCenterController.shared.show() }
    private func openSettings() { SettingsWindowController.shared.show() }
}

struct CommandPaletteView: View {
    @ObservedObject var model: CommandModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: model.isBusy ? "arrow.triangle.2.circlepath" : "scope")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("What do you want to do?", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20))
                    .focused($focused)
                    .onSubmit { model.executeFirst() }
                Text("⌘⇧Space").font(.caption.monospaced()).foregroundStyle(.tertiary)
            }
            .padding(18)
            Divider()
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(model.filtered) { command in
                        Button(action: command.action) {
                            HStack(spacing: 14) {
                                Image(systemName: command.icon).frame(width: 30)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(command.title).font(.system(size: 14, weight: .medium))
                                    Text(command.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(command.category).font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: .infinity)
            if let message = model.message {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: message.lowercased().contains("couldn't") ? "exclamationmark.circle" : "checkmark.circle.fill")
                    Text(message).lineLimit(2)
                    Spacer()
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(12)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.primary.opacity(0.08), lineWidth: 1) }
        .shadow(radius: 30, y: 14)
        .onAppear { focused = true }
    }
}

struct SettingsView: View {
    var body: some View {
        Form {
            Section("MacPilot") {
                LabeledContent("Global shortcut", value: "⌘⇧Space")
                LabeledContent("Architecture", value: "Native SwiftUI + AppKit")
                LabeledContent("Version", value: "0.3")
            }
            Section("Permissions") {
                Text("Accessibility controls application windows. Finder automation is used for explicit Finder actions. Audio controls use system volume APIs.")
                    .foregroundStyle(.secondary)
                Button("Request Accessibility Access") { WindowManager.requestAccessibility() }
            }
            Section("Privacy") {
                Text("Workspaces, command history, timeline events and automation rules are stored locally. Clipboard text is classified in memory only.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }
}
