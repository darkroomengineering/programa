import Foundation
import WebKit

extension BrowserPanel {
    func setBrowserThemeMode(_ mode: BrowserThemeMode) {
        browserThemeMode = mode
        applyBrowserThemeModeIfNeeded()
        for controller in popupControllers {
            controller.setBrowserThemeMode(mode)
        }
    }

    func refreshAppearanceDrivenColors() {
        webView.underPageBackgroundColor = GhosttyBackgroundTheme.currentColor()
    }

    func applyBrowserThemeModeIfNeeded() {
        BrowserThemeSettings.apply(browserThemeMode, to: webView)
    }
}
