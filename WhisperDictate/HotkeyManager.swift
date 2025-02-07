import Foundation
import Cocoa

class HotkeyManager: ObservableObject {
    private var lastOptionKeyPress: Date?
    private let doublePressInterval: TimeInterval = 0.3 // 300ms window for double press
    private var isOptionKeyDown = false
    private var localMonitor: Any?
    private var globalMonitor: Any?
    
    init() {
        setupEventHandling()
        
        // Register for workspace notifications to handle sleep/wake
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }
    
    private func setupEventHandling() {
        // Clean up any existing monitors
        cleanupMonitors()
        
        // Set up local monitor for modifier keys
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleEvent(event)
            return event
        }
        
        // Set up global monitor for all keys
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleEvent(event)
        }
    }
    
    private func handleEvent(_ event: NSEvent) {
        // Right option key has keyCode 61
        if event.keyCode == 61 {
            if event.type == .flagsChanged {
                // Check if the right option key was just pressed or released
                let isPressed = event.modifierFlags.contains(.option)
                
                if isPressed && !isOptionKeyDown {
                    // Option key was just pressed
                    isOptionKeyDown = true
                    handleOptionKeyPress()
                } else if !isPressed && isOptionKeyDown {
                    // Option key was just released
                    isOptionKeyDown = false
                }
            }
        }
    }
    
    private func handleOptionKeyPress() {
        let now = Date()
        
        if let lastPress = lastOptionKeyPress {
            let timeSinceLastPress = now.timeIntervalSince(lastPress)
            
            if timeSinceLastPress <= doublePressInterval {
                // Double press detected!
                print("HotkeyManager: Double press detected")
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: NSNotification.Name("HotkeyPressed"), object: nil)
                }
                lastOptionKeyPress = nil // Reset to prevent triple-press detection
                return
            }
        }
        
        lastOptionKeyPress = now
    }
    
    private func cleanupMonitors() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
    }
    
    @objc private func handleWake() {
        setupEventHandling()
    }
    
    deinit {
        cleanupMonitors()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
