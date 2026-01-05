import AppKit
import Combine
import Foundation

class SpacesViewModel: ObservableObject {
    @Published var spaces: [AnySpace] = []
    private var provider: AnySpacesProvider?
    private var accessibilityObserver: AccessibilityObserver?
    private var timer: Timer?

    init() {
        let runningApps = NSWorkspace.shared.runningApplications.compactMap {
            $0.localizedName?.lowercased()
        }
        if runningApps.contains("yabai") {
            provider = AnySpacesProvider(YabaiSpacesProvider())
        } else if runningApps.contains("aerospace") {
            provider = AnySpacesProvider(AerospaceSpacesProvider())
        } else {
            provider = nil
        }
        startMonitoring()
    }

    deinit {
        stopMonitoring()
    }

    private func startMonitoring() {
        // Use AccessibilityObserver for push-based focus change detection
        accessibilityObserver = AccessibilityObserver { [weak self] in
            self?.loadSpaces()
        }
        
        // Very slow fallback timer (30s) for edge cases like window moves within same app
        timer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) {
            [weak self] _ in
            self?.loadSpaces()
        }
        
        loadSpaces()
    }
    
    /// Force an immediate refresh of spaces data
    func refreshNow() {
        loadSpaces()
    }

    private func stopMonitoring() {
        accessibilityObserver?.stopObserving()
        accessibilityObserver = nil
        timer?.invalidate()
        timer = nil
    }

    private func loadSpaces() {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let provider = self.provider,
                let spaces = provider.getSpacesWithWindows()
            else {
                DispatchQueue.main.async {
                    self.spaces = []
                }
                return
            }
            let sortedSpaces = spaces.sorted { $0.id < $1.id }
            DispatchQueue.main.async {
                self.spaces = sortedSpaces
            }
        }
    }

    func switchToSpace(_ space: AnySpace, needWindowFocus: Bool = false) {
        DispatchQueue.global(qos: .userInitiated).async {
            self.provider?.focusSpace(
                spaceId: space.id, needWindowFocus: needWindowFocus)
            // Immediate refresh after user interaction
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.refreshNow()
            }
        }
    }

    func switchToWindow(_ window: AnyWindow) {
        DispatchQueue.global(qos: .userInitiated).async {
            self.provider?.focusWindow(windowId: String(window.id))
            // Immediate refresh after user interaction
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.refreshNow()
            }
        }
    }
}

class IconCache {
    static let shared = IconCache()
    private let cache = NSCache<NSString, NSImage>()
    private init() {}
    func icon(for appName: String) -> NSImage? {
        if let cached = cache.object(forKey: appName as NSString) {
            return cached
        }
        let workspace = NSWorkspace.shared
        if let app = workspace.runningApplications.first(where: {
            $0.localizedName == appName
        }),
            let bundleURL = app.bundleURL
        {
            let icon = workspace.icon(forFile: bundleURL.path)
            cache.setObject(icon, forKey: appName as NSString)
            return icon
        }
        return nil
    }
}
