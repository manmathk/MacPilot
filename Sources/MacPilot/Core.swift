import AppKit
import ApplicationServices
import Foundation

struct WindowSnapshot: Codable, Identifiable, Hashable {
    let id: UUID
    let bundleIdentifier: String
    let title: String
    let frame: CGRectCodable

    init(bundleIdentifier: String, title: String, frame: CGRect) {
        self.id = UUID()
        self.bundleIdentifier = bundleIdentifier
        self.title = title
        self.frame = CGRectCodable(frame)
    }
}

struct CGRectCodable: Codable, Hashable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        x = rect.origin.x; y = rect.origin.y; width = rect.width; height = rect.height
    }

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
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
                guard let rect = frame(of: window), rect.width > 120, rect.height > 80 else { continue }
                let title = attribute(window, kAXTitleAttribute) as? String ?? "Window"
                result.append(WindowSnapshot(bundleIdentifier: bundleID, title: title, frame: rect))
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
        let grouped = Dictionary(grouping: workspace.windows, by: { $0.bundleIdentifier })
        for (bundleID, desiredWindows) in grouped {
            guard let app = await ensureRunning(bundleID: bundleID) else { failed += desiredWindows.count; continue }
            app.activate(options: [.activateIgnoringOtherApps])
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            guard let current = attribute(axApp, kAXWindowsAttribute) as? [AXUIElement] else { failed += desiredWindows.count; continue }
            var remaining = current
            for desired in desiredWindows {
                guard let index = bestMatch(in: remaining, desired: desired) else { failed += 1; continue }
                let window = remaining.remove(at: index)
                if !visible(desired.frame.cgRect) { offscreen += 1 }
                if setFrame(of: window, to: visibleRect(desired.frame.cgRect)) { restored += 1 } else { failed += 1 }
            }
        }
        return .init(restored: restored, failed: failed, offscreen: offscreen)
    }

    private static func ensureRunning(bundleID: String) async -> NSRunningApplication? {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { return app }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        do {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            return try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        } catch { return nil }
    }

    private static func bestMatch(in windows: [AXUIElement], desired: WindowSnapshot) -> Int? {
        guard !windows.isEmpty else { return nil }
        return windows.enumerated().min { lhs, rhs in score(lhs.element, desired) < score(rhs.element, desired) }?.offset
    }

    private static func score(_ window: AXUIElement, _ desired: WindowSnapshot) -> Double {
        var score = 0.0
        if let title = attribute(window, kAXTitleAttribute) as? String, title == desired.title { score += 10000 }
        if let current = frame(of: window) {
            score -= abs(current.width - desired.frame.cgRect.width)
            score -= abs(current.height - desired.frame.cgRect.height)
        }
        return score
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let p = attribute(element, kAXPositionAttribute) as? AXValue, let s = attribute(element, kAXSizeAttribute) as? AXValue else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p, .cgPoint, &point), AXValueGetValue(s, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    private static func setFrame(of element: AXUIElement, to rect: CGRect) -> Bool {
        var point = rect.origin, size = rect.size
        guard let p = AXValueCreate(.cgPoint, &point), let s = AXValueCreate(.cgSize, &size) else { return false }
        let pr = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, p)
        let sr = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, s)
        return pr == .success && sr == .success
    }

    private static func attribute(_ element: AXUIElement, _ key: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value as AnyObject?
    }

    private static func visible(_ rect: CGRect) -> Bool { NSScreen.screens.contains { $0.visibleFrame.intersects(rect) } }

    private static func visibleRect(_ rect: CGRect) -> CGRect {
        guard !visible(rect), let screen = NSScreen.main else { return rect }
        var result = rect
        result.origin.x = screen.visibleFrame.midX - result.width / 2
        result.origin.y = screen.visibleFrame.midY - result.height / 2
        return result
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
        guard let value = execute(script), !value.isEmpty else { return nil }
        return URL(fileURLWithPath: value.trimmingCharacters(in: .whitespacesAndNewlines))
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
        let command = "cd \"\(escaped)\""
        let script = "tell application \"Terminal\" to do script \"\(command)\""
        return execute(script) != nil
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

    static func topLevelItems() -> [(name: String, bytes: Int64)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "/"), includingPropertiesForKeys: [.totalFileAllocatedSizeKey], options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { url in
            guard let bytes = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize, bytes > 0 else { return nil }
            return (url.lastPathComponent, Int64(bytes))
        }.sorted { $0.bytes > $1.bytes }
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
        if let intent = move(q) { return intent }
        return .unknown
    }

    private static func name(in q: String) -> String? {
        for marker in ["named ", "called "] {
            guard let range = q.range(of: marker) else { continue }
            let value = q[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { return value.capitalized }
        }
        return nil
    }

    private static func move(_ q: String) -> Intent? {
        guard q.hasPrefix("move ") else { return nil }
        let phrases = [" to monitor ", " to my monitor ", " to my second monitor", " to my third monitor"]
        for phrase in phrases {
            if let range = q.range(of: phrase) {
                let appName = String(q[q.index(q.startIndex, offsetBy: 5)..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                let suffix = q[range.upperBound...]
                let number = phrase.contains("second") ? 2 : (phrase.contains("third") ? 3 : Int(suffix.split(separator: " ").first ?? "1") ?? 1)
                if !appName.isEmpty { return .moveApp(appName.capitalized, number) }
            }
        }
        return nil
    }
}
