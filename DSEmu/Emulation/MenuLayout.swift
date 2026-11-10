// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Breakpoints for menus. Views use these with ViewThatFits, size classes and safe areas.
// Orientation, lid and window code are not involved.
import CoreGraphics

enum MenuLayout {
    /// Swatches across a menu-colors sheet. Always divides 16 themes.
    static func colorColumns(width: CGFloat) -> Int {
        width < 360 ? 2 : 4
    }

    /// Readable measure for a settings column on iPad; phones use the full width.
    static func readableWidth(_ width: CGFloat) -> CGFloat {
        guard width >= 700 else { return width }
        return min(680, width - 32)
    }

    /// Game info stacks the picture over the stats on a narrow or very short row.
    static func stacksGameInfo(width: CGFloat, height: CGFloat) -> Bool {
        if width < 520 { return true }
        if height > 0 && height < 400 && width < 700 { return true }
        return false
    }
}
