import SwiftUI
import Sparkle

// Bridges Sparkle's ObjC updater flag into SwiftUI so the menu button greys out
// while a check is already in flight.
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button(action: { updater.checkForUpdates() }) {
            HStack {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text("Check for Updates…")
            }
        }
        .disabled(!viewModel.canCheckForUpdates)
    }
}
