import SwiftUI
import AppKit

final class KeyEntryPanel {
    static let shared = KeyEntryPanel()
    private var window: NSPanel?
    
    func show(title: String, initialValue: String, onSave: @escaping (String) -> Void) {
        // If already shown, bring to front
        if let win = window {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let content = KeyEntryView(title: title, initialValue: initialValue) { value in
            onSave(value)
            self.close()
        } onCancel: {
            self.close()
        }
        
        let hosting = NSHostingController(rootView: content)
        let panel = NSPanel(contentViewController: hosting)
        panel.title = title
        panel.styleMask = [.titled, .closable, .utilityWindow]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.setContentSize(NSSize(width: 420, height: 160))
        panel.center()
        
        self.window = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
    
    func close() {
        window?.orderOut(nil)
        window = nil
    }
}

private struct KeyEntryView: View {
    let title: String
    let initialValue: String
    let onSave: (String) -> Void
    let onCancel: () -> Void
    @State private var value: String = ""
    
    init(title: String, initialValue: String, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.title = title
        self.initialValue = initialValue
        self.onSave = onSave
        self.onCancel = onCancel
        _value = State(initialValue: initialValue)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("Paste here", text: $value)
                .textFieldStyle(RoundedBorderTextFieldStyle())
            HStack {
                Button("Paste from Clipboard") {
                    if let s = NSPasteboard.general.string(forType: .string) {
                        value = s
                    }
                }
                Spacer()
                Button("Cancel") { onCancel() }
                Button("Save") {
                    onSave(value)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 380)
    }
}


