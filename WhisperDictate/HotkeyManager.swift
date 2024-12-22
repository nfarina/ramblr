import Foundation
import Carbon
import Cocoa

class HotkeyManager: ObservableObject {
    private var eventHandler: EventHandlerRef?
    var callback: (() -> Void)?
    
    init() {
        setupHotkey()
    }
    
    private func setupHotkey() {
        // Register CMD + SHIFT + R as the hotkey
        var hotKeyRef: EventHotKeyRef?
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
        
        var eventType = EventTypeSpec()
        eventType.eventClass = UInt32(kEventClassKeyboard)
        eventType.eventKind = UInt32(kEventHotKeyPressed)
        
        // Install handler
        InstallEventHandler(GetApplicationEventTarget(), { (_, inEvent, _) -> OSStatus in
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
                    NotificationCenter.default.post(name: NSNotification.Name("HotkeyPressed"), object: nil)
                }
            }
            return noErr
        }, 1, &eventType, nil, &eventHandler)
        
        // Register hotkey (CMD + SHIFT + R)
        RegisterEventHotKey(UInt32(kVK_ANSI_R),
                          UInt32(cmdKey | shiftKey),
                          gMyHotKeyID,
                          GetApplicationEventTarget(),
                          0,
                          &hotKeyRef)
    }
    
    deinit {
        if let eventHandler = eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }
}
