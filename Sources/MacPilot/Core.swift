import AppKit
import ApplicationServices
import Foundation

struct WindowSnapshot: Codable, Identifiable {
    let id: UUID
    let bundleIdentifier: String
    let title: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(bundleIdentifier: String, title: String, frame: CGRect) {
        id = UUID()
        self.bundleIdentifier = bundleIdentifier
        self.title = title
        x = frame.origin.x
        y = frame.origin.y
        width = frame.width
        height = frame.height
    }

    var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

struct WorkspaceSnapshot: Codable, Identifiable {
    let id: UUID
    var name: String
    var windows: [WindowSnapshot]
    let createdAt: Date
    var updatedAt: Date
}

struct WorkspaceRestoreResult {
    let restored: Int
    let failed: Int
    let offscreen: Int
}

struct WorkspaceStore {
    private let key = "MacPilot.workspaces.v2"

    var workspaces: [WorkspaceSnapshot] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([WorkspaceSnapshot].self, from: data)) ?? []
    }

    func saveCurrent(named name: String) -> WorkspaceSnapshot {
        let snapshot = WorkspaceSnapshot(id: UUID(), name: name, windows: WindowManager.captureWorkspace(), createdAt: Date(), updatedAt: Date())
        var values = workspaces
        if let index = values.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            values[index] = snapshot
        } else {
            values.append(snapshot)
        }
        if let data = try? JSONEncoder().encode(values) {
            UserDefaults.standard.set(data, forKey: key)
        }
        return snapshot
    }

    func restore(_ workspace: WorkspaceSnapshot) -> WorkspaceRestoreResult {
        WindowManager.restore(workspace)
    }
}

@MainActor
final class AXRuntime {
    static let shared = AXRuntime()
    private init() {}

    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}

private final class ApplicationBox: @unchecked Sendable {
    var app: NSRunningApplication?
}

enum WindowManager {
    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        Task { @MainActor in AXRuntime.shared.requestAccessibility() }
    }

    static func captureWorkspace() -> [WindowSnapshot] {
        guard isAccessibilityTrusted else { return [] }
        var result: [WindowSnapshot] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && !app.isTerminated {
            guard let bundleID = app.bundleIdentifier else { continue }
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            guard let windows = attribute(axApp, kAXWindowsAttribute) as? [AXUIElement] else { continue }
            for window in windows {
                guard let frame = frame(of: window), frame.width > 120, frame.height > 80 else { continue }
                let title = attribute(window, kAXTitleAttribute) as? String ?? "Window"
                result.append(WindowSnapshot(bundleIdentifier: bundleID, title: title, frame: frame))
            }
        }
        return result
    }

    static func restore(_ workspace: WorkspaceSnapshot) -> WorkspaceRestoreResult {
        guard isAccessibilityTrusted else {
            requestAccessibility()
            return .init(restored: 0, failed: workspace.windows.count, offscreen: 0)
        }
        var restored = 0
        var failed = 0
        var offscreen = 0

        for (bundleID, desired) in Dictionary(grouping: workspace.windows, by: { $0.bundleIdentifier }) {
            guard let app = launchIfNeeded(bundleID: bundleID) else {
                failed += desired.count
                continue
            }
            app.activate(options: [.activateIgnoringOtherApps])
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            guard let current = attribute(axApp, kAXWindowsAttribute) as? [AXUIElement] else {
                failed += desired.count
                continue
            }
            var remaining = current
            for wanted in desired {
                guard let index = remaining.indices.min(by: { score(remaining[$0], wanted) > score(remaining[$1], wanted) }) else {
                    failed += 1
                    continue
                }
                let window = remaining.remove(at: index)
                let rect = wanted.frame
                if !visible(rect) { offscreen += 1 }
                if setFrame(of: window, to: visibleRect(rect)) { restored += 1 } else { failed += 1 }
            }
        }
        return .init(restored: restored, failed: failed, offscreen: offscreen)
    }

    static func moveApp(named name: String, toMonitor monitor: Int) -> String {
        guard isAccessibilityTrusted else {
            requestAccessibility()
            return "Accessibility permission is required to move windows"
        }
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        guard let app = apps.first(where: { ($0.localizedName ?? "").localizedCaseInsensitiveContains(name) }) else { return "Couldn't find \(name)" }
        let screens = NSScreen.screens
        guard monitor > 0 && monitor <= screens.count else { return "Monitor \(monitor) isn't available" }
        let target = screens[monitor - 1].visibleFrame
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let windows = attribute(axApp, kAXWindowsAttribute) as? [AXUIElement], let window = windows.first else { return "Couldn't access \(name)'s window" }
        var point = CGPoint(x: target.minX + 24, y: target.maxY - 24 - min(target.height * 0.8, 720))
        guard let position = AXValueCreate(.cgPoint, &point), AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position) == .success else { return "Couldn't move \(name)'s window" }
        app.activate(options: [.activateIgnoringOtherApps])
        return "Moved \(name) to monitor \(monitor)"
    }

    private static func launchIfNeeded(bundleID: String) -> NSRunningApplication? {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { return app }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let semaphore = DispatchSemaphore(value: 0)
        let box = ApplicationBox()
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, _ in
            box.app = app
            semaphore.signal()
        }
        semaphore.wait()
        return box.app
    }

    private static func score(_ window: AXUIElement, _ desired: WindowSnapshot) -> Double {
        var value = 0.0
        if let title = attribute(window, kAXTitleAttribute) as? String, title == desired.title { value += 10000 }
        if let rect = frame(of: window) { value -= abs(rect.width - desired.width) + abs(rect.height - desired.height) }
        return value
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let rawPosition = attribute(element, kAXPositionAttribute), let rawSize = attribute(element, kAXSizeAttribute) else { return nil }
        let position = rawPosition as! AXValue
        let size = rawSize as! AXValue
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private static func setFrame(of element: AXUIElement, to rect: CGRect) -> Bool {
        var point = rect.origin
        var size = rect.size
        guard let position = AXValueCreate(.cgPoint, &point), let dimensions = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position) == .success && AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, dimensions) == .success
    }

    private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }

    private static func visible(_ rect: CGRect) -> Bool { NSScreen.screens.contains { $0.visibleFrame.intersects(rect) } }

    private static func visibleRect(_ rect: CGRect) -> CGRect {
        guard !visible(rect), let screen = NSScreen.main else { return rect }
        let maxX = screen.visibleFrame.maxX - min(rect.width, screen.visibleFrame.width)
        let maxY = screen.visibleFrame.maxY - min(rect.height, screen.visibleFrame.height)
        return CGRect(x: min(max(rect.minX, screen.visibleFrame.minX), maxX), y: min(max(rect.minY, screen.visibleFrame.minY), maxY), width: min(rect.width, screen.visibleFrame.width), height: min(rect.height, screen.visibleFrame.height))
    }
}

enum FinderService {
    static func selectedURLs() -> [URL] {
        let script = """
        tell application \"Finder\"
            set output to \"\"
            repeat with itemRef in (get selection)
                set output to output & (POSIX path of (itemRef as alias)) & linefeed
            end repeat
            return output
        end tell
        """
        return execute(script)?.split(separator: "\n").map { URL(fileURLWithPath: String($0)) } ?? []
    }

    static func currentDirectory() -> URL? {
        let script = """
        tell application \"Finder\"
            try
                return POSIX path of (target of front window as alias)
            on error
                return POSIX path of (path to desktop folder)
            end try
        end tell
        """
        guard let path = execute(script), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func copySelectedPath() -> String? {
        guard let url = selectedURLs().first else { return nil }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
        return url.path
    }

    static func openTerminalHere() -> Bool {
        guard let directory = currentDirectory() else { return false }
        let escaped = directory.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return execute("tell application \"Terminal\" to do script \"cd \\\"\(escaped)\\\"\"") != nil
    }

    private static func execute(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        return error == nil ? result.stringValue : nil
    }
}

enum StorageService {
    struct VolumeInfo { let total: Int64; let free: Int64 }
    static func volumeInfo() -> VolumeInfo {
        let attrs = (try? FileManager.default.attributesOfFileSystem(forPath: "/")) ?? [:]
        return .init(total: (attrs[.systemSize] as? NSNumber)?.int64Value ?? 0, free: (attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0)
    }
}

enum IntentParser {
    enum Intent: Equatable {
        case restore(String?)
        case save(String?)
        case moveApp(String, Int)
        case terminal
        case copyPath
        case storage
        case settings
        case accessibility
        case unknown
    }

    static func parse(_ input: String) -> Intent {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.contains("restore") && q.contains("workspace") { return .restore(name(in: q)) }
        if (q.contains("save") || q.contains("create")) && q.contains("workspace") { return .save(name(in: q)) }
        if q.contains("terminal") && (q.contains("here") || q.contains("folder")) { return .terminal }
        if q.contains("copy") && q.contains("path") { return .copyPath }
        if q.contains("storage") || q.contains("disk space") || q == "disk" { return .storage }
        if q.contains("accessibility") || q.contains("permission") { return .accessibility }
        if q.contains("settings") || q == "preferences" { return .settings }
        if let result = move(q) { return result }
        return .unknown
    }

    private static func name(in q: String) -> String? {
        for marker in ["named ", "called "] where q.contains(marker) {
            if let range = q.range(of: marker) {
                let value = q[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { return value.capitalized }
            }
        }
        return nil
    }

    private static func move(_ q: String) -> Intent? {
        guard q.hasPrefix("move ") else { return nil }
        if let range = q.range(of: " to monitor ") {
            let appName = String(q[q.index(q.startIndex, offsetBy: 5)..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let number = Int(q[range.upperBound...].split(separator: " ").first ?? "") ?? 1
            return appName.isEmpty ? nil : .moveApp(appName.capitalized, number)
        }
        if let range = q.range(of: " to my second monitor") {
            let appName = String(q[q.index(q.startIndex, offsetBy: 5)..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            return appName.isEmpty ? nil : .moveApp(appName.capitalized, 2)
        }
        if let range = q.range(of: " to my third monitor") {
            let appName = String(q[q.index(q.startIndex, offsetBy: 5)..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            return appName.isEmpty ? nil : .moveApp(appName.capitalized, 3)
        }
        return nil
    }
}
