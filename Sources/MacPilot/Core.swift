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
        id = UUID(); self.bundleIdentifier = bundleIdentifier; self.title = title
        x = frame.origin.x; y = frame.origin.y; width = frame.width; height = frame.height
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

enum WindowManager {
    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
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

    static func restore(_ workspace: WorkspaceSnapshot) async -> WorkspaceRestoreResult {
        guard isAccessibilityTrusted else {
            requestAccessibility()
            return .init(restored: 0, failed: workspace.windows.count, offscreen: 0)
        }
        var restored = 0, failed = 0, offscreen = 0
        for (bundleID, desired) in Dictionary(grouping: workspace.windows, by: { $0.bundleIdentifier }) {
            guard let app = await launchIfNeeded(bundleID: bundleID) else { failed += desired.count; continue }
            app.activate(options: [.activateIgnoringOtherApps])
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            guard let current = attribute(axApp, kAXWindowsAttribute) as? [AXUIElement] else { failed += desired.count; continue }
            var remaining = current
            for wanted in desired {
                guard let index = remaining.indices.min(by: { score(remaining[$0], wanted) > score(remaining[$1], wanted) }) else { failed += 1; continue }
                let window = remaining.remove(at: index)
                let rect = wanted.frame
                if !visible(rect) { offscreen += 1 }
                if setFrame(of: window, to: visibleRect(rect)) { restored += 1 } else { failed += 1 }
            }
        }
        return .init(restored: restored, failed: failed, offscreen: offscreen)
    }

    private static func launchIfNeeded(bundleID: String) async -> NSRunningApplication? {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { return app }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        do {
            let config = NSWorkspace.OpenConfiguration(); config.activates = true
            return try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        } catch { return nil }
    }

    private static func score(_ window: AXUIElement, _ desired: WindowSnapshot) -> Double {
        var value = 0.0
        if let title = attribute(window, kAXTitleAttribute) as? String, title == desired.title { value += 10000 }
        if let rect = frame(of: window) { value -= abs(rect.width - desired.width) + abs(rect.height - desired.height) }
        return value
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute) as? AXValue,
              let size = attribute(element, kAXSizeAttribute) as? AXValue else { return nil }
        var point = CGPoint.zero; var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private static func setFrame(of element: AXUIElement, to rect: CGRect) -> Bool {
        var point = rect.origin; var size = rect.size
        guard let position = AXValueCreate(.cgPoint, &point), let dimensions = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position) == .success &&
               AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, dimensions) == .success
    }

    private static func attribute(_ element: AXUIElement, _ key: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value as AnyObject?
    }

    private static func visible(_ rect: CGRect) -> Bool { NSScreen.screens.contains { $0.visibleFrame.intersects(rect) } }

    private static func visibleRect(_ rect: CGRect) -> CGRect {
        guard !visible(rect), let screen = NSScreen.main else { return rect }
        var adjusted = rect
        adjusted.origin.x = screen.visibleFrame.midX - rect.width / 2
        adjusted.origin.y = screen.visibleFrame.midY - rect.height / 2
        return adjusted
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
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.path, forType: .string)
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
