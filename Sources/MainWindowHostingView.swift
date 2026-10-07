import AppKit
import SwiftUI
import Bonsplit
import CoreServices
import UserNotifications
import Combine
import ObjectiveC.runtime
import Darwin

/// Non-generic marker so callers can test "is this the main window's hosting
/// view" without naming the generic parameter (used by the chrome-drag
/// fallback in WindowSwizzles to scope itself to main windows).
protocol MainWindowHostingViewMarker: AnyObject {}

final class MainWindowHostingView<Content: View>: NSHostingView<Content>, MainWindowHostingViewMarker {
    private let zeroSafeAreaLayoutGuide = NSLayoutGuide()

    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override var safeAreaRect: NSRect { bounds }
    override var safeAreaLayoutGuide: NSLayoutGuide { zeroSafeAreaLayoutGuide }

    required init(rootView: Content) {
        super.init(rootView: rootView)
        // Tell SwiftUI to ignore safe areas outright, rather than relying only on
        // the constant overrides above. Without this, SwiftUI keeps observing and
        // propagating safe-area changes even though the getters report zero, and
        // that observation is what recurses through invalidateSafeAreaInsets ->
        // didChangeValue(forKey:) -> setNeedsUpdateConstraints on ambient display
        // events until AppKit's layout-loop guard trips the app (issue #307).
        safeAreaRegions = []
        addLayoutGuide(zeroSafeAreaLayoutGuide)
        NSLayoutConstraint.activate([
            zeroSafeAreaLayoutGuide.leadingAnchor.constraint(equalTo: leadingAnchor),
            zeroSafeAreaLayoutGuide.trailingAnchor.constraint(equalTo: trailingAnchor),
            zeroSafeAreaLayoutGuide.topAnchor.constraint(equalTo: topAnchor),
            zeroSafeAreaLayoutGuide.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
