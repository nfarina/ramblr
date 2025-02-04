import Foundation
import Carbon
import Cocoa

class HotkeyManager: ObservableObject {
    private var eventHandler: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private var runLoopSource: CFRunLoopSource?
    var callback: (() -> Void)?
    
    init() {
        // Ensure we're running on the main thread
        if !Thread.isMainThread {
            DispatchQueue.main.sync {
                setupEventHandler()
            }
        } else {
            setupEventHandler()
        }
        
        // Register for workspace notifications to handle sleep/wake
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }
    
    private func setupEventHandler() {
        print("HotkeyManager: Setting up event handler")
        
        // Clean up existing handlers
        cleanupHotkey()
        
        // Create a run loop source for Carbon events
        var context = CFRunLoopSourceContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        
        if let source = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context) {
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        
        // Register for Carbon events
        var eventType = EventTypeSpec()
        eventType.eventClass = UInt32(kEventClassKeyboard)
        eventType.eventKind = UInt32(kEventHotKeyPressed)
        
        // Install handler
        let status = InstallEventHandler(
            GetEventMonitorTarget(), // Use monitor target instead of application target
            { (_, inEvent, _) -> OSStatus in
                var hotKeyID = EventHotKeyID()
                GetEventParameter(inEvent,
                                UInt32(kEventParamDirectObject),
                                UInt32(typeEventHotKeyID),
                                nil,
                                MemoryLayout<EventHotKeyID>.size,
                                nil,
                                &hotKeyID)
                
                if hotKeyID.id == 1 {
                    DispatchQueue.main.async {
                        print("HotkeyManager: Hotkey pressed!")
                        NotificationCenter.default.post(name: NSNotification.Name("HotkeyPressed"), object: nil)
                    }
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandler
        )
        
        if status != noErr {
            print("HotkeyManager: Failed to install event handler: \(status)")
            return
        }
        
        // Register the hotkey
        setupHotkey()
    }
    
    private func setupHotkey() {
        print("HotkeyManager: Registering hotkey")
        
        var gMyHotKeyID = EventHotKeyID()
        
        // Convert four-char code to OSType using Unicode scalars
        let fourCharCode = "htk1"
        let scalars = fourCharCode.unicodeScalars
        let signature = (UInt32(scalars[scalars.startIndex].value) << 24) |
                       (UInt32(scalars[scalars.index(after: scalars.startIndex)].value) << 16) |
                       (UInt32(scalars[scalars.index(scalars.startIndex, offsetBy: 2)].value) << 8) |
                       UInt32(scalars[scalars.index(scalars.startIndex, offsetBy: 3)].value)
        
        gMyHotKeyID.signature = FourCharCode(signature)
        gMyHotKeyID.id = UInt32(1)
        
        // Register hotkey (CMD + CTRL + R)
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_R),
            UInt32(cmdKey | controlKey),
            gMyHotKeyID,
            GetEventMonitorTarget(), // Use monitor target instead of application target
            0,
            &hotKeyRef
        )
        
        if registerStatus != noErr {
            print("HotkeyManager: Failed to register hotkey: \(registerStatus)")
        } else {
            print("HotkeyManager: Successfully registered hotkey")
        }
    }
    
    private func cleanupHotkey() {
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        
        if let eventHandler = eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
    }
    
    @objc private func handleWake() {
        print("HotkeyManager: System woke from sleep, reinitializing")
        setupEventHandler()
    }
    
    deinit {
        cleanupHotkey()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
