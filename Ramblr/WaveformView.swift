import SwiftUI

class WaveformModel: ObservableObject {
    @Published var audioLevels: [Float] = Array(repeating: 0.05, count: 10) // Start with minimal visible level
    
    func updateLevels(_ levels: [Float]) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Always update - even if empty, we want to show the change
            if levels.isEmpty {
                // Show minimal baseline activity
                self.audioLevels = Array(repeating: 0.05, count: 10)
                return 
            }
            
            // Take the most recent levels
            let recentLevels = Array(levels.suffix(10))
            
            // Ensure we have 10 levels
            if recentLevels.count < 10 {
                let paddedLevels = recentLevels + Array(repeating: 0.05, count: 10 - recentLevels.count)
                self.audioLevels = paddedLevels
            } else {
                self.audioLevels = recentLevels
            }
        }
    }
}

struct WaveformView: View {
    @ObservedObject var model: WaveformModel
    
    init(model: WaveformModel) {
        self.model = model
    }
    
    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<model.audioLevels.count, id: \.self) { index in
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(Color.white.opacity(0.8))
                    .frame(width: 2, height: max(1, min(10, CGFloat(model.audioLevels[index]) * 25)))
                    .animation(.easeInOut(duration: 0.25), value: model.audioLevels[index])
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}