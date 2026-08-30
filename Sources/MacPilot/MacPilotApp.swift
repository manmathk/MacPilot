import AppKit
import SwiftUI
import Combine

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
    private var globalHotKeyMonitor: Any?
    private var localHotKeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMenuBar()
        panelController = CommandPanelController()
        installHotKey()
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "scope", accessibilityDescription: "MacPilot")
        statusItem.menu = NSMenu()
        let open = NSMenuItem(title: "Open MacPilot", action: #selector(togglePanel), keyEquivalent: "")
        open.target = self
        statusItem.menu?.addItem(open)
        let workspace = NSMenuItem(title: "Save Workspace…", action: #selector(saveWorkspace), keyEquivalent: "")
        workspace.target = self
        statusItem.menu?.addItem(workspace)
        statusItem.menu?.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        statusItem.menu?.addItem(settings)
        let quit = NSMenuItem(title: "Quit MacPilot", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        statusItem.menu?.addItem(quit)
    }

    private func installHotKey() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains([.command, .shift]), event.keyCode == 49 else { return }
            Task { @MainActor [weak self] in self?.togglePanel() }
        }
        globalHotKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler)
        localHotKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handler(event)
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains([.command, .shift]), event.keyCode == 49 { return nil }
            return event
        }
    }

    @objc private func togglePanel() { panelController.toggle() }
    @objc private func saveWorkspace() { panelController.presentSaveWorkspace() }
    @objc private func openSettings() { panelController.openSettings() }
    @objc private func quit() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = globalHotKeyMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localHotKeyMonitor { NSEvent.removeMonitor(monitor) }
    }
}

@MainActor
final class CommandPanelController: NSObject {
    private let panel: NSPanel
    private let model: CommandModel

    override init() {
        model = CommandModel()
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 540), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
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
}

@MainActor
final class SettingsWindowController: NSObject {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingView(rootView: SettingsView().frame(width: 560, height: 460))
            let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 460), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            created.title = "MacPilot Settings"
            created.contentView = hosting
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
            Command(title: "Show Storage", subtitle: "Inspect disk capacity", icon: "internaldrive", category: "System") { [weak self] in self?.showStorage() },
            Command(title: "Accessibility Permission", subtitle: "Allow MacPilot to control windows", icon: "hand.raised", category: "System") { WindowManager.requestAccessibility() },
            Command(title: "Open Settings", subtitle: "Configure MacPilot", icon: "gearshape", category: "System") { [weak self] in self?.openSettings() }
        ]
    }

    var filtered: [Command] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return Array(commands.prefix(7)) }
        let terms = clean.lowercased().split(separator: " ")
        return commands.filter { command in
            let haystack = "\(command.title) \(command.subtitle) \(command.category)".lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }
    }

    var parsedIntent: IntentParser.Intent { IntentParser.parse(query) }
    func beginSession() { query = ""; message = nil; isBusy = false; workspaceCount = workspaceStore.workspaces.count }

    func executeFirst() {
        switch parsedIntent {
        case .restore(let name): restoreWorkspace(name: name)
        case .save(let name): saveWorkspace(name: name)
        case .moveApp(let appName, let monitor): moveApp(named: appName, toMonitor: monitor)
        case .terminal: openTerminalHere()
        case .copyPath: copyPath()
        case .storage: showStorage()
        case .settings: openSettings()
        case .accessibility: WindowManager.requestAccessibility()
        case .unknown: filtered.first?.action()
        }
    }

    private func restoreWorkspace(name: String? = nil) {
        guard let workspace = workspaceStore.workspaces.first(where: { name == nil || $0.name.caseInsensitiveCompare(name!) == .orderedSame }) ?? workspaceStore.workspaces.first else { message = "No saved workspaces yet"; return }
        guard WindowManager.isAccessibilityTrusted else { message = "Accessibility permission is required to restore windows"; WindowManager.requestAccessibility(); return }
        isBusy = true
        let result = workspaceStore.restore(workspace)
        message = result.offscreen > 0 ? "Restored \(result.restored); \(result.offscreen) moved back on-screen" : (result.failed == 0 ? "Restored \(result.restored) windows" : "Restored \(result.restored), \(result.failed) could not be restored")
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
    private func moveApp(named name: String, toMonitor monitor: Int) { message = WindowManager.moveApp(named: name, toMonitor: monitor) }
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
                Text("⌘⇧Space")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
            .padding(18)
            Divider()
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(model.filtered) { command in
                        Button(action: command.action) {
                            HStack(spacing: 14) {
                                Image(systemName: command.icon).frame(width: 30).font(.system(size: 15, weight: .semibold))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(command.title).font(.system(size: 14, weight: .medium))
                                    Text(command.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(command.category).font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
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
                LabeledContent("Version", value: "0.2 MVP")
            }
            Section("Permissions") {
                Text("Accessibility access lets MacPilot capture, move and restore application windows.")
                    .foregroundStyle(.secondary)
                Button("Request Accessibility Access") { WindowManager.requestAccessibility() }
            }
            Section("Privacy") {
                Text("Workspace snapshots are stored locally.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }
}
