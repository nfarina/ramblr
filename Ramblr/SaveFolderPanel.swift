import SwiftUI
import AppKit

final class SaveFolderPanel {
    static let shared = SaveFolderPanel()
    private var window: NSPanel?

    func show(folderPath: String, subdirectoryFormat: String, onSave: @escaping (String, String) -> Void) {
        if let win = window {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let content = SaveFolderView(
            initialFolderPath: folderPath,
            initialFormat: subdirectoryFormat
        ) { path, format in
            onSave(path, format)
            self.close()
        } onCancel: {
            self.close()
        }

        let hosting = NSHostingController(rootView: content)
        let panel = NSPanel(contentViewController: hosting)
        panel.title = "Save Transcriptions"
        panel.styleMask = [.titled, .closable, .utilityWindow]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.setContentSize(NSSize(width: 440, height: 200))
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

private struct SaveFolderView: View {
    let onSave: (String, String) -> Void
    let onCancel: () -> Void
    @State private var folderPath: String
    @State private var subdirectoryFormat: String

    init(initialFolderPath: String, initialFormat: String, onSave: @escaping (String, String) -> Void, onCancel: @escaping () -> Void) {
        self.onSave = onSave
        self.onCancel = onCancel
        _folderPath = State(initialValue: initialFolderPath)
        _subdirectoryFormat = State(initialValue: initialFormat)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save Transcriptions").font(.headline)

            HStack {
                Text("Folder:")
                if folderPath.isEmpty {
                    Text("None selected")
                        .foregroundColor(.secondary)
                } else {
                    Text(abbreviatePath(folderPath))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Choose...") {
                    chooseFolder()
                }
            }

            HStack {
                Text("Subfolder format:")
                TextField("{year}/{month}/{day}", text: $subdirectoryFormat)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
            }

            Text("Tokens: {year} {month} {day} {hour} {minute}")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                Button("Save") {
                    onSave(folderPath, subdirectoryFormat)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 400)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Transcription Save Folder"
        panel.prompt = "Select"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true

        if !folderPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: folderPath)
        }

        let response = panel.runModal()
        guard response == .OK, let selectedURL = panel.url else { return }
        folderPath = selectedURL.path
    }

    private func abbreviatePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
