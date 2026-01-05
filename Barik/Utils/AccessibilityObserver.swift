import AppKit
import ApplicationServices

/// Observes system-wide window focus changes using macOS Accessibility APIs.
/// This provides push-based notifications without polling, resulting in near-zero energy impact.
class AccessibilityObserver {
    private var observers: [pid_t: AXObserver] = [:]
    private var runningAppsObserver: NSObjectProtocol?
    private var onFocusChange: (() -> Void)?
    
    init(onFocusChange: @escaping () -> Void) {
        self.onFocusChange = onFocusChange
        
        // Check and request accessibility permissions
        let trusted = Self.checkAccessibilityPermissions()
        if trusted {
            setupObservers()
        } else {
            // If not trusted, set up a timer to check periodically until granted
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.retrySetupIfNeeded()
            }
        }
    }
    
    /// Checks accessibility permissions, prompting the user if needed
    static func checkAccessibilityPermissions() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
    
    private func retrySetupIfNeeded() {
        if AXIsProcessTrusted() {
            setupObservers()
        } else {
            // Keep checking every 2 seconds until permission is granted
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.retrySetupIfNeeded()
            }
        }
    }
    
    deinit {
        stopObserving()
    }
    
    private func setupObservers() {
        // Observe all currently running apps
        for app in NSWorkspace.shared.runningApplications {
            if app.activationPolicy == .regular {
                addObserver(for: app)
            }
        }
        
        // Watch for new apps launching
        runningAppsObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.addObserver(for: app)
            }
        }
        
        // Clean up when apps terminate
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.removeObserver(for: app.processIdentifier)
            }
            // Trigger refresh on app terminate
            self?.onFocusChange?()
        }
    }
    
    private func addObserver(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid > 0, observers[pid] == nil else { return }
        
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon = refcon else { return }
            let observer = Unmanaged<AccessibilityObserver>.fromOpaque(refcon).takeUnretainedValue()
            observer.onFocusChange?()
        }
        
        let result = AXObserverCreate(pid, callback, &observer)
        guard result == .success, let observer = observer else { return }
        
        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        
        // Watch for focused window changes
        AXObserverAddNotification(observer, appElement, kAXFocusedWindowChangedNotification as CFString, refcon)
        // Watch for main window changes
        AXObserverAddNotification(observer, appElement, kAXMainWindowChangedNotification as CFString, refcon)
        // Watch for application activation
        AXObserverAddNotification(observer, appElement, kAXApplicationActivatedNotification as CFString, refcon)
        // Watch for new windows
        AXObserverAddNotification(observer, appElement, kAXWindowCreatedNotification as CFString, refcon)
        
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }
    
    private func removeObserver(for pid: pid_t) {
        if let observer = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
    }
    
    func stopObserving() {
        for (pid, _) in observers {
            removeObserver(for: pid)
        }
        observers.removeAll()
        
        if let observer = runningAppsObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            runningAppsObserver = nil
        }
    }
}
