import AppKit
import SwiftUI

@main
struct MacPilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .frame(width: 520, height: 420)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panelController: CommandPanelController!
    private var hotKeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "scope", accessibilityDescription: "MacPilot")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open MacPilot", action: #selector(togglePanel), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Quit MacPilot", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu

        panelController = CommandPanelController()

        hotKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.contains([.command, .shift]), event.charactersIgnoringModifiers == " " else { return }
            self?.togglePanel()
        }
    }

    @objc private func togglePanel() {
        panelController.toggle()
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = hotKeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

final class CommandPanelController {
    private let panel: NSPanel
    private let model = CommandModel()

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: CommandPaletteView(model: model))
    }

    func toggle() {
        if panel.isVisible {
            panel.orderOut(nil)
            return
        }

        model.reset()
        let screen = NSScreen.main ?? NSScreen.screens.first
        if let screen {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: visible.midX - panel.frame.width / 2,
                y: visible.midY - panel.frame.height / 2 + 80
            ))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
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
        let action: () -> Void
    }

    @Published var query = ""
    @Published var message: String?

    private(set) var commands: [Command] = []

    init() {
        commands = [
            Command(title: "Restore Coding Workspace", subtitle: "Bring your coding windows back", icon: "rectangle.3.group", category: "Workspaces", action: { [weak self] in self?.restoreWorkspace() }),
            Command(title: "Create Workspace from Current Setup", subtitle: "Save your current window arrangement", icon: "square.and.arrow.down", category: "Workspaces", action: { [weak self] in self?.saveWorkspace() }),
            Command(title: "Open Terminal Here", subtitle: "Open Terminal at the focused Finder folder", icon: "terminal", category: "Finder", action: { [weak self] in self?.openTerminalHere() }),
            Command(title: "Copy Selected File Path", subtitle: "Copy the path of the selected Finder item", icon: "link", category: "Finder", action: { [weak self] in self?.copyPath() }),
            Command(title: "Show Storage", subtitle: "See a storage overview for this Mac", icon: "internaldrive", category: "System", action: { [weak self] in self?.showStorage() }),
            Command(title: "Mute Current App", subtitle: "Open audio controls for the active application", icon: "speaker.slash", category: "Audio", action: { [weak self] in self?.showAudio() })
        ]
    }

    var filtered: [Command] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return Array(commands.prefix(6)) }
        let terms = clean.lowercased().split(separator: " ")
        return commands.filter { command in
            let haystack = "\(command.title) \(command.subtitle) \(command.category)".lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }
    }

    func reset() {
        query = ""
        message = nil
    }

    private func openTerminalHere() {
        let script = "tell application \"Terminal\" to activate"
        executeAppleScript(script)
        message = "Terminal opened"
    }

    private func copyPath() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let file = NSOpenPanel.selectURL() {
            pasteboard.setString(file.path, forType: .string)
            message = "Path copied"
        } else {
            message = "Select a Finder item first"
        }
    }

    private func restoreWorkspace() {
        WorkspaceManager.restoreDefaultCodingWorkspace()
        message = "Coding workspace restored"
    }

    private func saveWorkspace() {
        WorkspaceManager.saveCurrentWorkspace(named: "Coding")
        message = "Workspace saved"
    }

    private func showStorage() {
        let bytes = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first.flatMap { url -> Int64? in
            do { return try FileManager.default.attributesOfFileSystem(forPath: url.path)[.systemFreeSize] as? Int64 } catch { return nil }
        }
        if let bytes {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            message = "Free space: \(formatter.string(fromByteCount: bytes))"
        } else {
            message = "Storage information unavailable"
        }
    }

    private func showAudio() {
        message = "Audio controls are available in the next MVP module"
    }

    private func executeAppleScript(_ source: String) {
        guard let script = NSAppleScript(source: source) else { return }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
    }
}

struct CommandPaletteView: View {
    @ObservedObject var model: CommandModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "scope")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.secondary)

                TextField("What do you want to do?", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20, weight: .regular))
                    .focused($focused)
                    .onSubmit {
                        model.filtered.first?.action()
                    }

                Text("⌘⇧Space")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
            .padding(18)

            Divider()

            if model.filtered.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("No matching commands")
                        .font(.headline)
                    Text("Try “restore workspace”, “terminal”, or “storage”.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(model.filtered) { command in
                            Button {
                                command.action()
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: command.icon)
                                        .frame(width: 30)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(.primary)

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(command.title)
                                            .font(.system(size: 15, weight: .medium))
                                        Text(command.subtitle)
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    Text(command.category)
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                }
            }

            if let message = model.message {
                Divider()
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                    Text(message)
                    Spacer()
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(12)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.primary.opacity(0.08), lineWidth: 1)
        }
        .shadow(radius: 30, y: 14)
        .onAppear { focused = true }
    }
}

struct SettingsView: View {
    var body: some View {
        Form {
            Section("MacPilot") {
                LabeledContent("Global shortcut", value: "⌘⇧Space")
                LabeledContent("Version", value: "0.1 MVP")
            }
            Section("Privacy") {
                Text("MacPilot is designed to keep command history and workspace data local to your Mac.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }
}

enum WorkspaceManager {
    static func saveCurrentWorkspace(named name: String) {
        let workspace = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { $0.bundleIdentifier }
        UserDefaults.standard.set(workspace, forKey: "workspace.\(name).bundleIDs")
    }

    static func restoreDefaultCodingWorkspace() {
        let apps = UserDefaults.standard.stringArray(forKey: "workspace.Coding.bundleIDs") ?? ["com.apple.Terminal", "com.apple.finder"]
        for bundleID in apps {
            NSWorkspace.shared.launchApplication(withBundleIdentifier: bundleID, options: [.default], additionalEventParamDescriptor: nil, launchIdentifier: nil)
        }
    }
}

private extension NSOpenPanel {
    static func selectURL() -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}
