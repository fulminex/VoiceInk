import Foundation
import AppKit
import os

enum BrowserType {
    case safari
    case arc
    case chrome
    case edge
    case firefox
    case brave
    case opera
    case vivaldi
    case orion
    case zen
    case yandex
    
    var scriptName: String {
        switch self {
        case .safari: return "safariURL"
        case .arc: return "arcURL"
        case .chrome: return "chromeURL"
        case .edge: return "edgeURL"
        case .firefox: return "firefoxURL"
        case .brave: return "braveURL"
        case .opera: return "operaURL"
        case .vivaldi: return "vivaldiURL"
        case .orion: return "orionURL"
        case .zen: return "zenURL"
        case .yandex: return "yandexURL"
        }
    }
    
    var bundleIdentifier: String {
        switch self {
        case .safari: return "com.apple.Safari"
        case .arc: return "company.thebrowser.Browser"
        case .chrome: return "com.google.Chrome"
        case .edge: return "com.microsoft.edgemac"
        case .firefox: return "org.mozilla.firefox"
        case .brave: return "com.brave.Browser"
        case .opera: return "com.operasoftware.Opera"
        case .vivaldi: return "com.vivaldi.Vivaldi"
        case .orion: return "com.kagi.kagimacOS"
        case .zen: return "app.zen-browser.zen"
        case .yandex: return "ru.yandex.desktop.yandex-browser"
        }
    }
    
    var displayName: String {
        switch self {
        case .safari: return "Safari"
        case .arc: return "Arc"
        case .chrome: return "Google Chrome"
        case .edge: return "Microsoft Edge"
        case .firefox: return "Firefox"
        case .brave: return "Brave"
        case .opera: return "Opera"
        case .vivaldi: return "Vivaldi"
        case .orion: return "Orion"
        case .zen: return "Zen Browser"
        case .yandex: return "Yandex Browser"
        }
    }
    
    static var allCases: [BrowserType] {
        [.safari, .arc, .chrome, .edge, .brave, .opera, .vivaldi, .orion, .yandex]
    }
    
    static var installedBrowsers: [BrowserType] {
        allCases.filter { browser in
            let workspace = NSWorkspace.shared
            return workspace.urlForApplication(withBundleIdentifier: browser.bundleIdentifier) != nil
        }
    }
}

enum BrowserURLError: Error {
    case scriptNotFound
    case executionFailed
    case browserNotRunning
    case noActiveWindow
    case noActiveTab
}

class BrowserURLService {
    static let shared = BrowserURLService()

    private let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink",
        category: "browser.applescript"
    )

    private init() {}

    func getCurrentURL(from browser: BrowserType, targetPID: pid_t? = nil) async throws -> String {
        // Check if browser is running
        if !isRunning(browser) {
            logger.error("❌ Browser not running: \(browser.displayName, privacy: .public)")
            throw BrowserURLError.browserNotRunning
        }

        // Try AppleScript first
        do {
            let url = try await getCurrentURLViaAppleScript(from: browser)
            return url
        } catch {
            logger.warning("⚠️ AppleScript failed for \(browser.displayName, privacy: .public), trying Accessibility API fallback: \(error.localizedDescription, privacy: .public)")
        }

        // Fallback: use Accessibility API targeting the specific PID
        if let pid = targetPID ?? frontmostPID(for: browser) {
            if let url = getURLViaAccessibility(pid: pid) {
                logger.debug("✅ Retrieved URL via Accessibility API for \(browser.displayName, privacy: .public): \(url, privacy: .public)")
                return url
            }
            logger.error("❌ Accessibility API also failed for \(browser.displayName, privacy: .public)")
        }

        throw BrowserURLError.executionFailed
    }

    // MARK: - AppleScript method

    private func getCurrentURLViaAppleScript(from browser: BrowserType) async throws -> String {
        guard let scriptURL = Bundle.main.url(forResource: browser.scriptName, withExtension: "scpt") else {
            logger.error("❌ AppleScript file not found: \(browser.scriptName, privacy: .public).scpt")
            throw BrowserURLError.scriptNotFound
        }

        logger.debug("🔍 Attempting to execute AppleScript for \(browser.displayName, privacy: .public)")

        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = [scriptURL.path]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        logger.debug("▶️ Executing AppleScript for \(browser.displayName, privacy: .public)")
        try task.run()
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if output.isEmpty {
                throw BrowserURLError.noActiveTab
            }

            if output.lowercased().contains("error") {
                logger.error("❌ AppleScript error for \(browser.displayName, privacy: .public): \(output, privacy: .public)")
                throw BrowserURLError.executionFailed
            }

            logger.debug("✅ Successfully retrieved URL from \(browser.displayName, privacy: .public): \(output, privacy: .public)")
            return output
        }

        throw BrowserURLError.executionFailed
    }

    // MARK: - Accessibility API fallback

    /// Get the browser URL using the Accessibility API, targeting a specific process by PID.
    /// This avoids the issue where AppleScript targets the wrong process when multiple
    /// instances of the same browser are running (e.g., Playwright Chrome alongside normal Chrome).
    private func getURLViaAccessibility(pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)

        // Try focused window first (more reliable than AXWindows which can return empty)
        var window: AnyObject?
        var result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &window)

        // Fallback to first window from AXWindows
        if result != .success || window == nil {
            var windows: AnyObject?
            result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windows)
            guard result == .success,
                  let windowArray = windows as? [AXUIElement],
                  let firstWindow = windowArray.first else {
                return nil
            }
            window = firstWindow
        }

        // Chromium-based browsers and Safari expose the URL via kAXDocumentAttribute
        var urlValue: AnyObject?
        let urlResult = AXUIElementCopyAttributeValue(window as! AXUIElement, kAXDocumentAttribute as CFString, &urlValue)

        if urlResult == .success, let url = urlValue as? String, !url.isEmpty {
            return url
        }

        return nil
    }

    /// Find the PID of the frontmost instance of a browser
    private func frontmostPID(for browser: BrowserType) -> pid_t? {
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == browser.bundleIdentifier
        }

        // Prefer the active (frontmost) instance, otherwise pick the one with windows
        if let active = runningApps.first(where: { $0.isActive }) {
            return active.processIdentifier
        }

        // Try each instance and return the first one that has windows
        for app in runningApps {
            let pid = app.processIdentifier
            let appElement = AXUIElementCreateApplication(pid)
            var windows: AnyObject?
            let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windows)
            if result == .success, let windowArray = windows as? [AXUIElement], !windowArray.isEmpty {
                return pid
            }
        }

        return runningApps.first?.processIdentifier
    }

    func isRunning(_ browser: BrowserType) -> Bool {
        let workspace = NSWorkspace.shared
        let runningApps = workspace.runningApplications
        let isRunning = runningApps.contains { $0.bundleIdentifier == browser.bundleIdentifier }
        logger.debug("\(browser.displayName, privacy: .public) running status: \(isRunning, privacy: .public)")
        return isRunning
    }
} 
