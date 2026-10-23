import Foundation
import SwiftUI

/// Direction from which a new split animates in
enum SplitAnimationOrigin {
    case fromFirst   // New pane slides in from start (left/top)
    case fromSecond  // New pane slides in from end (right/bottom)
}

/// State for a split node (branch in the split tree)
@Observable
final class SplitState: Identifiable {
    let id: UUID
    var orientation: SplitOrientation
    var first: SplitNode
    var second: SplitNode
    var dividerPosition: CGFloat  // 0.0 to 1.0

    /// Animation origin for entry animation (nil = no animation needed)
    var animationOrigin: SplitAnimationOrigin?

    init(
        id: UUID = UUID(),
        orientation: SplitOrientation,
        first: SplitNode,
        second: SplitNode,
        dividerPosition: CGFloat = 0.5,
        animationOrigin: SplitAnimationOrigin? = nil
    ) {
        self.id = id
        self.orientation = orientation
        self.first = first
        self.second = second
        self.dividerPosition = dividerPosition
        self.animationOrigin = animationOrigin
    }

    /// Splits `rect` at `dividerPosition`: horizontal puts first on the left, vertical puts first on top.
    func childBounds(in rect: CGRect) -> (first: CGRect, second: CGRect) {
        switch orientation {
        case .horizontal:
            return (
                CGRect(x: rect.minX, y: rect.minY, width: rect.width * dividerPosition, height: rect.height),
                CGRect(x: rect.minX + rect.width * dividerPosition, y: rect.minY,
                       width: rect.width * (1 - dividerPosition), height: rect.height)
            )
        case .vertical:
            return (
                CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * dividerPosition),
                CGRect(x: rect.minX, y: rect.minY + rect.height * dividerPosition,
                       width: rect.width, height: rect.height * (1 - dividerPosition))
            )
        }
    }
}

extension SplitState: Equatable {
    static func == (lhs: SplitState, rhs: SplitState) -> Bool {
        lhs.id == rhs.id
    }
}
