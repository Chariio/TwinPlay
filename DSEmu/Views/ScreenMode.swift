// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import SwiftUI

/// Which DS screens are shown.
enum ScreenMode: String, CaseIterable, Identifiable {
    case both, topOnly, bottomOnly
    var id: String { rawValue }
    var label: String { englishLabel.loc }
    /// English source text (the String Catalog key).
    var englishLabel: String {
        switch self {
        case .both: return "Both screens"
        case .topOnly: return "Top screen only"
        case .bottomOnly: return "Bottom screen only"
        }
    }
    /// An iPhone Duo that is not folded shut shows both DS screens whatever the per-game mode.
    static func duoShowsBoth(isGBA: Bool, isDuo: Bool, onOuter: Bool) -> Bool { !isGBA && isDuo && !onOuter }
    var next: ScreenMode {
        switch self { case .both: return .topOnly; case .topOnly: return .bottomOnly; case .bottomOnly: return .both }
    }
    /// The single screen shown (0 top, 1 bottom), or nil for both. `peek` swaps it temporarily.
    func shownScreen(peek: Bool) -> Int? {
        switch self {
        case .both: return nil
        case .topOnly: return peek ? 1 : 0
        case .bottomOnly: return peek ? 0 : 1
        }
    }
}

extension DualScreenLayout {
    /// Scales each screen about its centre, optionally snaps it to a whole multiple of the DS
    /// resolution in device pixels, and keeps it inside `bounds`.
    func resized(top ts: Double, bottom bs: Double, snap: Bool, displayScale: CGFloat, bounds: CGRect) -> DualScreenLayout {
        var l = self
        func adjust(_ r: CGRect, _ f: Double) -> CGRect {
            guard r.width > 1, r.height > 1 else { return r }
            let aspect = r.width / r.height
            var w = r.width * CGFloat(f)
            if snap {
                let srcW: CGFloat = abs(aspect - 1.5) < 0.01 ? 240 : abs(aspect - 160.0 / 144.0) < 0.01 ? 160 : 256   // GBA 240, GB 160, DS 256
                let px = w * displayScale
                let k = max(1, (px / srcW).rounded(.down))
                w = k * srcW / displayScale
            }
            var h = w / aspect
            if w > bounds.width { w = bounds.width; h = w / aspect }
            if h > bounds.height { h = bounds.height; w = h * aspect }
            var x = r.midX - w / 2, y = r.midY - h / 2
            x = min(max(x, bounds.minX), bounds.maxX - w)
            y = min(max(y, bounds.minY), bounds.maxY - h)
            return CGRect(x: x, y: y, width: w, height: h)
        }
        l.top = adjust(top, ts)
        if !isSingle { l.bottom = adjust(bottom, bs) }
        return l
    }
}

extension DualScreenLayout {
    /// Screens on whole device pixels (origin and size). A screen at a fractional position or
    /// size is resampled by the compositor on top of the filter, which blurred small text when
    /// the screens were enlarged; aligned, the shader's filter is the only scaling.
    func pixelAligned(scale: CGFloat) -> DualScreenLayout {
        guard scale > 0 else { return self }
        func snap(_ r: CGRect) -> CGRect {
            guard r.width > 1, r.height > 1 else { return r }
            let x0 = (r.minX * scale).rounded() / scale, y0 = (r.minY * scale).rounded() / scale
            let x1 = (r.maxX * scale).rounded() / scale, y1 = (r.maxY * scale).rounded() / scale
            return CGRect(x: x0, y: y0, width: max(x1 - x0, 1 / scale), height: max(y1 - y0, 1 / scale))
        }
        var l = self
        l.top = snap(top)
        if !isSingle { l.bottom = snap(bottom) }
        return l
    }
}
