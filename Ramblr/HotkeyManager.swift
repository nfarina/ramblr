import Foundation
import Carbon
import Cocoa

class HotkeyManager: ObservableObject {
    private var eventHandler: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    
    // Persisted hotkey configuration
    @Published private(set) var keyCode: UInt32
    @Published private(set) var modifiers: UInt32
    
    private let keyCodeDefaultsKey = "HotkeyKeyCode"
    private let modifiersDefaultsKey = "HotkeyModifiers"
    
    init() {
        logInfo("HotkeyManager: Initializing")
        // Load persisted hotkey or default to Option+D
        let storedKeyCode = UserDefaults.standard.object(forKey: keyCodeDefaultsKey) as? Int
        let storedModifiers = UserDefaults.standard.object(forKey: modifiersDefaultsKey) as? UInt32
        self.keyCode = UInt32(storedKeyCode ?? Int(kVK_ANSI_D))
        self.modifiers = storedModifiers ?? UInt32(optionKey)
        setupHotkey(keyCode: keyCode, modifiers: modifiers)
        
        // Register for workspace notifications to handle sleep/wake
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }
    
    private func setupHotkey(keyCode: UInt32, modifiers: UInt32) {
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
                        logDebug("HotkeyManager: Hotkey pressed")
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
            logError("HotkeyManager: Failed to install event handler")
            return
        }
        
        // Register the configured hotkey
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            gMyHotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        
        if registerStatus != noErr {
            logError("HotkeyManager: Failed to register hotkey")
        } else {
            logInfo("HotkeyManager: Successfully registered hotkey: \(displayString)")
        }
    }
    
    private func cleanupHotkey() {
        logDebug("HotkeyManager: Cleaning up hotkey resources")
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
        logInfo("HotkeyManager: System woke from sleep, reinstalling hotkey")
        setupHotkey(keyCode: keyCode, modifiers: modifiers)
    }
    
    deinit {
        logInfo("HotkeyManager: Deinitializing")
        cleanupHotkey()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Public API
    
    func updateHotkey(keyCode: UInt32, modifiers: UInt32) {
        logInfo("HotkeyManager: Updating hotkey")
        self.keyCode = keyCode
        self.modifiers = modifiers
        UserDefaults.standard.set(Int(keyCode), forKey: keyCodeDefaultsKey)
        UserDefaults.standard.set(modifiers, forKey: modifiersDefaultsKey)
        setupHotkey(keyCode: keyCode, modifiers: modifiers)
    }
    
    var displayString: String {
        let symbols = Self.symbols(forCarbonModifiers: modifiers)
        let key = Self.keyName(fromKeyCode: keyCode) ?? "KeyCode \(keyCode)"
        return symbols + key
    }
    
    // MARK: - Helpers
    
    static func carbonFlags(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }
    
    static func symbols(forCarbonModifiers mods: UInt32) -> String {
        var s = ""
        if (mods & UInt32(cmdKey)) != 0 { s += "⌘" }
        if (mods & UInt32(optionKey)) != 0 { s += "⌥" }
        if (mods & UInt32(shiftKey)) != 0 { s += "⇧" }
        if (mods & UInt32(controlKey)) != 0 { s += "⌃" }
        return s
    }
    
    static func keyName(fromKeyCode keyCode: UInt32) -> String? {
        // Basic mapping for common keys (letters, digits, function keys)
        let letterMap: [UInt32: String] = [
            UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
            UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
            UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
            UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
            UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
            UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
            UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
            UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
            UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z"
        ]
        if let name = letterMap[keyCode] { return name }
        let digitMap: [UInt32: String] = [
            UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
            UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
            UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
            UInt32(kVK_ANSI_9): "9"
        ]
        if let name = digitMap[keyCode] { return name }
        let otherMap: [UInt32: String] = [
            UInt32(kVK_Space): "Space",
            UInt32(kVK_Escape): "Esc",
            UInt32(kVK_Return): "Return",
            UInt32(kVK_Tab): "Tab",
            UInt32(kVK_Delete): "Delete",
            UInt32(kVK_ForwardDelete): "Forward Delete",
            UInt32(kVK_Help): "Help",
            UInt32(kVK_Home): "Home",
            UInt32(kVK_End): "End",
            UInt32(kVK_PageUp): "Page Up",
            UInt32(kVK_PageDown): "Page Down",
            UInt32(kVK_LeftArrow): "←",
            UInt32(kVK_RightArrow): "→",
            UInt32(kVK_UpArrow): "↑",
            UInt32(kVK_DownArrow): "↓"
        ]
        if let name = otherMap[keyCode] { return name }
        // Function keys F1–F20 (Carbon key codes are not contiguous; map explicitly)
        let functionMap: [UInt32: String] = [
            UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3", UInt32(kVK_F4): "F4",
            UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6", UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8",
            UInt32(kVK_F9): "F9", UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
            UInt32(kVK_F13): "F13", UInt32(kVK_F14): "F14", UInt32(kVK_F15): "F15", UInt32(kVK_F16): "F16",
            UInt32(kVK_F17): "F17", UInt32(kVK_F18): "F18", UInt32(kVK_F19): "F19", UInt32(kVK_F20): "F20"
        ]
        if let name = functionMap[keyCode] { return name }
        return nil
    }
}
