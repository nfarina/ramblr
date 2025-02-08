import Foundation
import Carbon
import Cocoa

class HotkeyManager: ObservableObject {
    private var eventHandler: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    
    init() {
        setupHotkey()
        
        // Register for workspace notifications to handle sleep/wake
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }
    
    private func setupHotkey() {
        // Clean up any existing handlers
        cleanupHotkey()
        
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
        
        // Install handler
        var eventType = EventTypeSpec()
        eventType.eventClass = OSType(kEventClassKeyboard)
        eventType.eventKind = OSType(kEventHotKeyPressed)
        
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
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
                        print("HotkeyManager: Hotkey pressed")
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
            print("HotkeyManager: Failed to install event handler")
            return
        }
        
        // Register Option+D as the hotkey (D = 0x02)
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_D),
            UInt32(optionKey),
            gMyHotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        
        if registerStatus != noErr {
            print("HotkeyManager: Failed to register hotkey")
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
    }
    
    @objc private func handleWake() {
        setupHotkey()
    }
    
    deinit {
        cleanupHotkey()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
