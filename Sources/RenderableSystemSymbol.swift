import SwiftUI

/// Helpers for sizing SF Symbols safely across macOS 26+ launch/layout timing.
///
/// `Image(systemName:)` sized purely via `.font(.system(size:))` can rasterize at
/// 0x0 during a window's pre-visible layout pass, because font metrics aren't
/// resolved yet at that point. macOS 26+ rejects a 0x0 symbol raster target with an
/// uncaught `NSInvalidArgumentException` (`targetSizeInPoints.width/height>0`),
/// crashing the app on launch. Driving the raster size from an explicit, clamped
/// `.frame()` instead keeps it positive across every layout pass.
enum RenderableSystemSymbol {
    private static let minimumRasterPointSize: CGFloat = 1

    static func clampedRasterPointSize(_ pointSize: CGFloat) -> CGFloat {
        guard pointSize.isFinite else {
            return minimumRasterPointSize
        }
        return max(minimumRasterPointSize, pointSize)
    }
}

extension Image {
    /// Drives the SF Symbol's raster size from an explicit positive frame instead of
    /// transient font metrics. Visual result is unchanged from a directly font-sized
    /// symbol of the same point size and weight.
    func symbolRasterSize(
        _ pointSize: CGFloat,
        weight: Font.Weight? = nil,
        alignment: Alignment = .center
    ) -> some View {
        let rasterSize = RenderableSystemSymbol.clampedRasterPointSize(pointSize)
        let systemFont: Font = weight.map { .system(size: rasterSize, weight: $0) } ?? .system(size: rasterSize)
        return font(systemFont)
            .frame(width: rasterSize, height: rasterSize, alignment: alignment)
    }
}
