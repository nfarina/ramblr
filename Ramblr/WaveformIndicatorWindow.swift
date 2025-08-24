import SwiftUI
import AppKit

final class WaveformIndicatorWindow: ObservableObject {
    static let shared = WaveformIndicatorWindow()
    private var window: NSPanel?
    private var hostingController: NSHostingController<WaveformIndicatorView>?
    private var waveformModel = WaveformModel()
    
    private init() {}
    
    func show() {
        // If already shown, just return
        if let window = window, window.isVisible {
            return
        }
        
        let waveformView = WaveformIndicatorView(model: waveformModel) {
            // Click handler to open menu bar menu
            self.openMenuBarMenu()
        }
        
        let hosting = NSHostingController(rootView: waveformView)
        hostingController = hosting
        
        let panel = NSPanel(contentViewController: hosting)
        panel.styleMask = [.borderless, .nonactivatingPanel]
        panel.backgroundColor = NSColor.clear
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level.statusBar
        panel.setContentSize(NSSize(width: 60, height: 20))
        
        // Position at top center of screen, below menu bar
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let windowSize = panel.frame.size
            let x = screenFrame.midX - (windowSize.width / 2)
            let y = screenFrame.maxY - windowSize.height - 8 // 8pt below menu bar
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        
        self.window = panel
        panel.orderFront(nil)
    }
    
    func hide() {
        window?.orderOut(nil)
        window = nil
        hostingController = nil
    }
    
    func updateAudioLevels(_ levels: [Float]) {
        waveformModel.updateLevels(levels)
    }
    
    private func openMenuBarMenu() {
        // Find and click the menu bar item to open the menu
        if NSApp.windows.first(where: { $0.className.contains("MenuBar") }) != nil {
            // This is a simplified approach - in practice we'd need to trigger the menu bar
            // For now, we'll just hide the indicator as clicking should focus the menu
            hide()
            
            // Try to activate the menu bar extra
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

private struct WaveformIndicatorView: View {
    @ObservedObject var model: WaveformModel
    let onTap: () -> Void
    
    var body: some View {
        ZStack {
            // Black pill background
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black.opacity(0.8))
                .frame(width: 60, height: 20)
            
            // Waveform content
            WaveformView(model: model)
                .frame(width: 50, height: 12)
        }
        .onTapGesture {
            onTap()
        }
        .background(Color.clear)
    }
}

