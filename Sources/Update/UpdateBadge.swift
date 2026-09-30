import SwiftUI

/// A badge view that displays the current state of an update operation.
struct UpdateBadge: View {
    @ObservedObject var model: UpdateViewModel

    var body: some View {
        badgeContent
            .accessibilityLabel(model.text)
    }

    @ViewBuilder
    private var badgeContent: some View {
        if model.showsDetectedBackgroundUpdate {
            if let iconName = model.iconName {
                Image(systemName: iconName)
            }
        } else {
            switch model.effectiveState {
            case .downloading(let download):
                if let expectedLength = download.expectedLength, expectedLength > 0 {
                    let progress = min(1, max(0, Double(download.progress) / Double(expectedLength)))
                    ProgressRingView(progress: progress)
                } else {
                    Image(systemName: "arrow.down.circle")
                }

            case .extracting(let extracting):
                ProgressRingView(progress: min(1, max(0, extracting.progress)))

            case .checking:
                BrowserStyleLoadingSpinner(size: 14, color: model.foregroundColor)

            default:
                if let iconName = model.iconName {
                    Image(systemName: iconName)
                }
            }
        }
    }
}

fileprivate struct ProgressRingView: View {
    let progress: Double
    let lineWidth: CGFloat = 2

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.2), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.primary, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.2), value: progress)
        }
    }
}

fileprivate struct BrowserStyleLoadingSpinner: View {
    let size: CGFloat
    let color: Color
    @State private var angle: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.20), lineWidth: ringWidth)
            Circle()
                .trim(from: 0.0, to: 0.28)
                .stroke(color, style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
                .rotationEffect(.degrees(angle))
        }
        .frame(width: size, height: size)
        .onAppear {
            // 0.9s per revolution; one repeating animation instead of a per-frame body.
            angle = 360
        }
        .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: angle)
    }

    private var ringWidth: CGFloat {
        max(1.6, size * 0.14)
    }
}
