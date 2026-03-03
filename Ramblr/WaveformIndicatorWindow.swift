import SwiftUI
import AppKit

enum IndicatorMode {
    case waveform
    case transcribing
}

final class WaveformIndicatorWindow: ObservableObject {
    static let shared = WaveformIndicatorWindow()
    private var window: NSPanel?
    private var hostingController: NSHostingController<WaveformIndicatorView>?
    private var waveformModel = WaveformModel()
    @Published var mode: IndicatorMode = .waveform
    @Published var opacity: Double = 0.0
    @Published var clipboardOnly: Bool = false
    @Published var showOutputMode: Bool = false
    
    private init() {}
    
    func show() {
        // If already shown, just return
        if let window = window, window.isVisible {
            return
        }
        
        let waveformView = WaveformIndicatorView(model: waveformModel, windowModel: self) {
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
        let windowWidth: CGFloat = showOutputMode ? 200 : 60
        panel.setContentSize(NSSize(width: windowWidth, height: 20))
        
        // Position at top center of screen, below menu bar
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let windowSize = panel.frame.size
            let x = screenFrame.midX - (windowSize.width / 2)
            let y = screenFrame.maxY - windowSize.height - 8 // 8pt below menu bar
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        
        self.window = panel
        
        // Start with opacity 0 and fade in
        opacity = 0.0
        panel.orderFront(nil)
        
        // Animate fade in
        withAnimation(.easeOut(duration: 0.2)) {
            opacity = 1.0
        }
    }
    
    func hide() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Animate fade out
            withAnimation(.easeIn(duration: 0.1)) {
                self.opacity = 0.0
            }
            
            // Hide window after animation completes
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.window?.orderOut(nil)
                self.window = nil
                self.hostingController = nil
            }
        }
    }
    
    func updateAudioLevels(_ levels: [Float]) {
        waveformModel.updateLevels(levels)
    }
    
    func showWaveform(clipboardOnly: Bool = false, showOutputMode: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            self?.mode = .waveform
            self?.clipboardOnly = clipboardOnly
            self?.showOutputMode = showOutputMode
            self?.show()
        }
    }
    
    func showTranscribing() {
        DispatchQueue.main.async { [weak self] in
            self?.mode = .transcribing
            self?.show()
        }
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

private struct PulsingDotsView: View {
    @State private var pulse1 = false
    @State private var pulse2 = false
    @State private var pulse3 = false
    
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.white.opacity(pulse1 ? 1.0 : 0.3))
                .frame(width: 4, height: 4)
                .animation(.easeInOut(duration: 0.6).repeatForever(), value: pulse1)
            
            Circle()
                .fill(Color.white.opacity(pulse2 ? 1.0 : 0.3))
                .frame(width: 4, height: 4)
                .animation(.easeInOut(duration: 0.6).repeatForever(), value: pulse2)
            
            Circle()
                .fill(Color.white.opacity(pulse3 ? 1.0 : 0.3))
                .frame(width: 4, height: 4)
                .animation(.easeInOut(duration: 0.6).repeatForever(), value: pulse3)
        }
        .onAppear {
            // Start animations with staggered timing
            pulse1 = true
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                pulse2 = true
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                pulse3 = true
            }
        }
        .onDisappear {
            pulse1 = false
            pulse2 = false
            pulse3 = false
        }
    }
}

private struct WaveformIndicatorView: View {
    @ObservedObject var model: WaveformModel
    @ObservedObject var windowModel: WaveformIndicatorWindow
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            // Waveform / transcribing pill
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.8))
                    .frame(width: 60, height: 20)

                Group {
                    switch windowModel.mode {
                    case .waveform:
                        WaveformView(model: model)
                            .frame(width: 50, height: 12)
                    case .transcribing:
                        PulsingDotsView()
                            .frame(width: 50, height: 12)
                    }
                }
            }
            .onTapGesture {
                onTap()
            }

            // Output mode pill (only during waveform/recording, when auto-paste is relevant)
            if windowModel.showOutputMode && windowModel.mode == .waveform {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.black.opacity(0.8))
                        .frame(height: 20)

                    Text(windowModel.clipboardOnly ? "clipboard" : "auto-paste")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.horizontal, 8)
                }
                .fixedSize()
                .onTapGesture {
                    windowModel.clipboardOnly.toggle()
                }
            }
        }
        .opacity(windowModel.opacity)
        .background(Color.clear)
    }
}

