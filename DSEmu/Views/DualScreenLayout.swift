// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import CoreGraphics

enum ScreenArrangement: String, CaseIterable, Identifiable {
    case automatic, stacked, sideBySide
    var id: String { rawValue }
    var label: String { englishLabel.loc }
    /// English source text (the String Catalog key).
    var englishLabel: String {
        switch self {
        case .automatic: return "Automatic"
        case .stacked: return "Stacked"
        case .sideBySide: return "Side by side"
        }
    }
}

/// Computes where the two 256x192 (4:3) screens go for any container size:
/// small/large iPhones, iPads, Split View, tall or nearly square (foldable) displays.
struct DualScreenLayout: Equatable {
    var top: CGRect
    var bottom: CGRect
    var isPortrait: Bool
    var isSideBySide: Bool
    /// Free area for on-screen controls (below the screens in portrait, the whole view in landscape).
    var controlsArea: CGRect
    /// Single-screen layout (Game Boy Advance): only `top` is used; `bottom` is empty.
    var isSingle = false
    /// Compact controls hugging the edges of `controlsArea` (iPhone Duo lower panel), leaving the
    /// middle for a large touch screen. `compactUnit` is the D-pad / face-button cluster size.
    var compactUnit: CGFloat = 0
    /// iPhone Duo "pearl shell" presentation: each screen centred in its half, hinge bar along
    /// the fold. `hinge` is the division region (full-screen coordinates), `.zero` otherwise.
    var twin = false
    var hinge: CGRect = .zero
    /// Closed iPhone Duo, outer display in landscape: full-bleed classic handheld shell (Game Boy
    /// family). `top` is the game screen; controls come from `outerSpots`.
    var outer = false
    var outerGBA = false

    static let dsWidth: CGFloat = 256
    static let dsHeight: CGFloat = 192

    /// Top band (full-screen coordinates) the corner buttons live in. Phones with a Dynamic Island /
    /// notch already have it as safe-area inset, so nothing is reserved there and the screens
    /// start right under the inset; other displays reserve the difference.
    static let topBand: CGFloat = 48
    static func topReserve(forInset inset: CGFloat) -> CGFloat { max(0, topBand - inset) }

    /// `topReserve`: height kept free at the top of `size` (see `topReserve(forInset:)`).
    static func make(size: CGSize, arrangement: ScreenArrangement, showsControls: Bool, topReserve: CGFloat = 0) -> DualScreenLayout {
        let w = max(size.width, 1), h = max(size.height, 1)
        let portrait = h >= w
        let gap: CGFloat = 6

        if portrait {
            // Reserve the lower part for controls; never less than ~55% for screens.
            let reserve = showsControls ? min(max(h * 0.31, 205), h * 0.45) : 0
            let availH = h - reserve
            let bar = topReserve
            if arrangement == .sideBySide {
                let s = min(w / (dsWidth * 2 + gap), (availH - bar) / dsHeight)
                return sideBySide(scale: s, in: CGRect(x: 0, y: bar, width: w, height: availH - bar), gap: gap,
                                  portrait: true, controls: CGRect(x: 0, y: availH, width: w, height: reserve))
            }
            let s = min(w / dsWidth, (availH - bar - gap) / (dsHeight * 2))
            let sw = dsWidth * s, sh = dsHeight * s
            let x = (w - sw) / 2
            let used = sh * 2 + gap
            let y0 = bar + max(0, (availH - bar - used) / 2)
            let top = CGRect(x: x, y: y0, width: sw, height: sh)
            let bottom = CGRect(x: x, y: y0 + sh + gap, width: sw, height: sh)
            return DualScreenLayout(top: top, bottom: bottom, isPortrait: true, isSideBySide: false,
                                    controlsArea: CGRect(x: 0, y: bottom.maxY, width: w, height: h - bottom.maxY))
        }

        // Landscape: controls overlay the sides, so screens may use the whole height.
        let stackedScale = min(w / dsWidth, (h - gap) / (dsHeight * 2))
        var sideScale = min(w / (dsWidth * 2 + gap), h / dsHeight)
        // With touch controls the sides are the controller: side by side must leave gutters for
        // the D-pad and buttons, or they would cover the screens.
        let room = controlGutter(width: w, height: h)
        let gutteredSide = min((w - room * 2) / (dsWidth * 2 + gap), h / dsHeight)
        let useSide: Bool
        switch arrangement {
        case .automatic:
            let sideGutter = (w - (dsWidth * 2 + gap) * sideScale) / 2
            useSide = sideScale > stackedScale && (!showsControls || sideGutter >= room)
        case .stacked: useSide = false
        case .sideBySide: useSide = true
        }
        if useSide && showsControls { sideScale = min(sideScale, max(gutteredSide, 0.5)) }
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        if useSide {
            return sideBySide(scale: sideScale, in: full, gap: gap, portrait: false, controls: full)
        }
        let sw = dsWidth * stackedScale, sh = dsHeight * stackedScale
        let x = (w - sw) / 2
        let y0 = (h - (sh * 2 + gap)) / 2
        return DualScreenLayout(top: CGRect(x: x, y: y0, width: sw, height: sh),
                                bottom: CGRect(x: x, y: y0 + sh + gap, width: sw, height: sh),
                                isPortrait: false, isSideBySide: false, controlsArea: full)
    }

    /// One 3:2 screen (GBA, 240x160). Portrait: at the top with controls below. Landscape: as large as
    /// possible while leaving room at the sides for the controls when they are shown.
    /// `portraitMargin`: room left and right of the screen in portrait (detailed shells draw a
    /// bezel and logo there).
    static func makeSingle(size: CGSize, showsControls: Bool, aspect: CGFloat = 240.0 / 160.0, portraitMargin: CGFloat = 12, topReserve: CGFloat = 0) -> DualScreenLayout {
        let w = max(size.width, 1), h = max(size.height, 1)
        let portrait = h >= w
        if portrait {
            let reserve = showsControls ? min(max(h * 0.40, 250), h * 0.55) : 0
            let availH = h - reserve - topReserve
            let sw = min(w - portraitMargin * 2, availH * aspect), sh = sw / aspect
            let top = CGRect(x: (w - sw) / 2, y: topReserve + max(0, (availH - sh) / 2), width: sw, height: sh)
            return DualScreenLayout(top: top, bottom: .zero, isPortrait: true, isSideBySide: false,
                                    controlsArea: CGRect(x: 0, y: top.maxY, width: w, height: h - top.maxY), isSingle: true)
        }
        let sideRoom: CGFloat = showsControls ? min(w * 0.22, 210) : 0
        let maxW = w - sideRoom * 2, maxH = h - 8
        let sw = min(maxW, maxH * aspect), sh = sw / aspect
        let top = CGRect(x: (w - sw) / 2, y: (h - sh) / 2, width: sw, height: sh)
        return DualScreenLayout(top: top, bottom: .zero, isPortrait: false, isSideBySide: false,
                                controlsArea: CGRect(x: 0, y: 0, width: w, height: h), isSingle: true)
    }

    /// Side room the landscape touch controls need (a 96-180pt cluster plus margins).
    static func controlGutter(width w: CGFloat, height h: CGFloat) -> CGFloat {
        min(max(min(h * 0.36, 180) + 16, 112), w * 0.2)
    }

    private static func sideBySide(scale s: CGFloat, in r: CGRect, gap: CGFloat, portrait: Bool, controls: CGRect) -> DualScreenLayout {
        let sw = dsWidth * s, sh = dsHeight * s
        let x0 = r.minX + (r.width - (sw * 2 + gap)) / 2
        let y = r.minY + (r.height - sh) / 2
        return DualScreenLayout(top: CGRect(x: x0, y: y, width: sw, height: sh),
                                bottom: CGRect(x: x0 + sw + gap, y: y, width: sw, height: sh),
                                isPortrait: portrait, isSideBySide: true, controlsArea: controls)
    }
}

extension DualScreenLayout {
    /// Moves every rect (used to place a layout computed in the safe area into full-screen coordinates).
    func offsetBy(dx: CGFloat, dy: CGFloat) -> DualScreenLayout {
        var l = self
        l.top = top.offsetBy(dx: dx, dy: dy)
        l.bottom = isSingle ? bottom : bottom.offsetBy(dx: dx, dy: dy)
        l.controlsArea = controlsArea.offsetBy(dx: dx, dy: dy)
        return l
    }

    /// The area to lay the screens out in, and its origin, inside the full screen. In landscape the
    /// safe-area insets are applied symmetrically (the larger of left/right and of top/bottom on
    /// both sides) so the screens are centred on the display whichever way the phone is turned.
    static func safeFrame(full: CGSize, insets: (top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat)) -> CGRect {
        if full.width > full.height {
            let hx = max(insets.leading, insets.trailing), vy = max(insets.top, insets.bottom)
            return CGRect(x: hx, y: vy, width: max(full.width - hx * 2, 1), height: max(full.height - vy * 2, 1))
        }
        // Portrait: symmetric left/right too (e.g. a side camera cut-out), so the screens stay centred.
        let hx = max(insets.leading, insets.trailing)
        return CGRect(x: hx, y: insets.top, width: max(full.width - hx * 2, 1),
                      height: max(full.height - insets.top - insets.bottom, 1))
    }

    /// Widescreen 3D: shows the top screen at 16:9 (4/3 wider), shrinking it if it does not fit.
    func widenedTop(in size: CGSize) -> DualScreenLayout {
        var l = self
        var w = top.width * 4 / 3, h = top.height
        let maxW = isSideBySide ? max(size.width - bottom.width - 6, 1) : size.width
        if w > maxW { h *= maxW / w; w = maxW }
        let x = isSideBySide ? max(0, top.maxX - w) : (size.width - w) / 2
        l.top = CGRect(x: x, y: top.maxY - h, width: w, height: h)
        return l
    }
}

// MARK: - Foldables (iPhone Duo)

/// How a foldable is being held, from the iOS 27.1 hinge status (`DeviceHinge.Status`).
enum FoldPosture: Equatable {
    /// Unknown or not a foldable: use the normal phone layout.
    case flat
    /// Folded shut (iPhone Duo): the game pauses behind the TwinPlay lid.
    case closed
    /// Half open (book / laptop): keep everything off the hinge.
    case book
    /// Fully open: one big display with a flat crease.
    case open

    /// Posture from the hinge angle (degrees; 180 = flat open, 0 = shut), for hinge states the
    /// status does not name. Fully flat counts from 170 degrees, like the system's "fully open".
    static func from(angle: Double) -> FoldPosture {
        if angle < 5 { return .closed }
        return angle >= 170 ? .open : .book
    }
}

extension DualScreenLayout {
    /// Splits `safe` into the two panels on either side of `hinge` (the division region). Returns
    /// the "first" panel (upper, or leading when the hinge is vertical) and the second one.
    static func panels(safe: CGRect, hinge: CGRect) -> (first: CGRect, second: CGRect, vertical: Bool) {
        let vertical = hinge.height > hinge.width
        if vertical {
            let a = CGRect(x: safe.minX, y: safe.minY, width: max(hinge.minX - safe.minX, 1), height: safe.height)
            let b = CGRect(x: hinge.maxX, y: safe.minY, width: max(safe.maxX - hinge.maxX, 1), height: safe.height)
            return (a, b, true)
        }
        // Horizontal hinge: the upper panel keeps the safe area (front camera), but the lower
        // panel has no cutout, so let it span nearly the hinge's full width.
        let x0 = min(safe.minX, max(hinge.minX, safe.minX - 72)), x1 = max(safe.maxX, min(hinge.maxX, safe.maxX + 72))
        let a = CGRect(x: safe.minX, y: safe.minY, width: safe.width, height: max(hinge.minY - safe.minY, 1))
        let b = CGRect(x: x0, y: hinge.maxY, width: x1 - x0, height: max(safe.maxY - hinge.maxY, 1))
        return (a, b, false)
    }

    /// Largest rect of the given aspect ratio centred in `r` after insetting it.
    static func fit(_ aspect: CGFloat, in r: CGRect, inset: CGFloat = 8) -> CGRect {
        let a = r.insetBy(dx: min(inset, r.width / 4), dy: min(inset, r.height / 4))
        let w = min(a.width, a.height * aspect), h = w / aspect
        return CGRect(x: a.midX - w / 2, y: a.midY - h / 2, width: w, height: h)
    }

    /// Layout for a half-open or fully open foldable, in full-screen coordinates. `safe` is the
    /// safe area, `hinge` the division region reported by the system. Nothing is put on the hinge.
    static func makeFolded(safe: CGRect, hinge: CGRect, posture: FoldPosture, isGBA: Bool,
                           showsControls: Bool, gbaAspect: CGFloat = 240.0 / 160.0, twin: Bool = false) -> DualScreenLayout {
        let (first, second, vertical) = panels(safe: safe, hinge: hinge)
        let ds = dsWidth / dsHeight
        if twin && !isGBA && showsControls && !vertical {
            return makeTwin(first: first, second: second, hinge: hinge)
        }

        if isGBA && !vertical {
            // Book or fully open: the screen fills the upper panel at 3:2, its bottom edge 2pt
            // clear of the hinge, the top kept below the front camera; the lower panel is the
            // controller, so nothing overlaps the screen or the hinge.
            let cameraClearance: CGFloat = 76
            let x0 = max(hinge.minX, safe.minX - 72) + 2, x1 = min(hinge.maxX, safe.maxX + 72) - 2
            let maxH = hinge.minY - 2 - max(safe.minY, cameraClearance)
            let w = min(x1 - x0, maxH * gbaAspect), h = w / gbaAspect
            let top = CGRect(x: (x0 + x1) / 2 - w / 2, y: hinge.minY - 2 - h, width: w, height: h)
            return DualScreenLayout(top: top, bottom: .zero, isPortrait: true, isSideBySide: false,
                                    controlsArea: second, isSingle: true)
        }
        if isGBA {
            if posture == .book {
                // Screen on the upper panel; the lower panel becomes the controller.
                let top = fit(gbaAspect, in: first, inset: 10)
                return DualScreenLayout(top: top, bottom: .zero, isPortrait: true, isSideBySide: false,
                                        controlsArea: second, isSingle: true)
            }
            // Fully open: one large screen across the whole display.
            var single = makeSingle(size: safe.size, showsControls: showsControls, aspect: gbaAspect)
            single = single.offsetBy(dx: safe.minX, dy: safe.minY)
            return single
        }

        let top = fit(ds, in: first, inset: posture == .book ? 8 : 4)
        if showsControls && !vertical {
            // Stacked panels: touch screen centred in the lower panel with the D-pad and buttons
            // beside it (like a real DS), L/R in the top corners, Start/Select underneath.
            // Compact clusters in narrow side columns so the touch screen can be about as large
            // as the top screen.
            let unit = min(max(second.width * 0.15, 60), 76)
            let side = unit + 6
            let area = CGRect(x: second.minX + side, y: second.minY + 6, width: second.width - side * 2,
                              height: second.height - 6 - 34)
            var bottom = fit(ds, in: area, inset: 0)
            // Both screens the same width, centred, and hugging the hinge (2pt clear of it) so
            // art spanning both screens looks almost continuous, like a real DS.
            let topMax = fit(ds, in: first, inset: 4)
            let w = min(topMax.width, bottom.width), h = w * dsHeight / dsWidth
            let mid = (first.midX + second.midX) / 2
            let topR = CGRect(x: mid - w / 2, y: hinge.minY - 2 - h, width: w, height: h)
            bottom = CGRect(x: mid - w / 2, y: hinge.maxY + 2, width: w, height: h)
            var l = DualScreenLayout(top: topR, bottom: bottom, isPortrait: false, isSideBySide: false,
                                     controlsArea: second)
            l.compactUnit = unit
            return l
        }
        if showsControls {
            // Side-by-side panels: touch screen at the top of its panel, controls in a strip below.
            let reserve = max(min(second.height * 0.42, 280), 210)
            let area = CGRect(x: second.minX, y: second.minY + 4, width: second.width,
                              height: max(second.height - reserve - 4, 60))
            let bottom = fit(ds, in: area, inset: 6)
            return DualScreenLayout(top: top, bottom: bottom, isPortrait: true, isSideBySide: true,
                                    controlsArea: CGRect(x: second.minX, y: bottom.maxY + 4, width: second.width,
                                                         height: second.maxY - bottom.maxY - 4))
        }
        // No touch controls: each DS screen as large as its half of the display allows.
        let bottom = fit(ds, in: second, inset: posture == .book ? 6 : 4)
        return DualScreenLayout(top: top, bottom: bottom, isPortrait: posture == .book && vertical,
                                isSideBySide: vertical, controlsArea: second)
    }
}


extension DualScreenLayout {
    /// Hinge bar band drawn along the fold (raised), never covered by a screen.
    static func twinBar(hinge: CGRect) -> CGRect { hinge.insetBy(dx: 0, dy: -max(0, (26 - hinge.height) / 2)) }

    /// iPhone Duo fully open, pearl handheld look: top screen centred in the upper half between
    /// the speaker grilles, a raised hinge bar along the fold with L/R under its ends, and the
    /// touch screen centred in the lower half between the D-pad and the face buttons.
    static func makeTwin(first: CGRect, second: CGRect, hinge: CGRect, cameraClearance: CGFloat = 76) -> DualScreenLayout {
        let ds = dsWidth / dsHeight
        let bar = twinBar(hinge: hinge)
        // Reference proportions: big D-pad / face-button clusters in wide side columns.
        let unit = min(max(second.width * 0.17, 62), 104)
        let side = unit + 22
        // Upper half: side room for the grilles, clear of the hinge bar. The horizontal safe
        // inset (front camera at a corner) only matters near the top edge, so use the lower
        // panel's span and keep the screen below the camera band.
        let upY = max(first.minY + 10, cameraClearance)
        let upArea = CGRect(x: second.minX + side * 0.8, y: upY,
                            width: second.width - side * 1.6, height: bar.minY - 16 - upY)
        // Lower half: a row for the L/R labels under the bar, side columns for the clusters.
        let loTop = bar.maxY + 30
        let loArea = CGRect(x: second.minX + side, y: loTop, width: second.width - side * 2,
                            height: second.maxY - 14 - loTop)
        let a = fit(ds, in: upArea, inset: 0), b = fit(ds, in: loArea, inset: 0)
        let w = min(a.width, b.width), h = w / ds
        let mid = (first.midX + second.midX) / 2
        let top = CGRect(x: mid - w / 2, y: upArea.midY - h / 2, width: w, height: h)
        let bottom = CGRect(x: mid - w / 2, y: loArea.midY - h / 2, width: w, height: h)
        var l = DualScreenLayout(top: top, bottom: bottom, isPortrait: false, isSideBySide: false, controlsArea: second)
        l.compactUnit = unit
        l.twin = true
        l.hinge = hinge
        return l
    }

    /// #14 iPad (any large window, incl. Split View / Stage Manager): the DS reference layout of
    /// ds-skin-ref, which is drawn for these proportions: top screen in the upper half, an L / MIC
    /// / R bar across the middle, the touch screen between the D-pad and the face buttons. Nil when
    /// the window is small (phones) or far from the reference proportions (then the regular layout).
    static func makeReference(frame f: CGRect) -> DualScreenLayout? {
        guard min(f.width, f.height) >= 600 else { return nil }
        let aspect = f.width / f.height
        guard (0.6...0.86).contains(aspect) || (1.2...1.62).contains(aspect) else { return nil }
        let hinge = CGRect(x: f.minX, y: (f.midY - 6).rounded(), width: f.width, height: 12)
        let first = CGRect(x: f.minX, y: f.minY, width: f.width, height: hinge.minY - f.minY)
        let second = CGRect(x: f.minX, y: hinge.maxY, width: f.width, height: f.maxY - hinge.maxY)
        return makeTwin(first: first, second: second, hinge: hinge, cameraClearance: f.minY + 50)   // room for the corner buttons
    }

    /// Centres of the Duo controls (shared by the touch layer and the shell artwork).
    /// `home` is the MENU button's default spot (round button, label on its left).
    struct TwinSpots { var dpad: CGPoint; var face: CGPoint; var home: CGPoint; var start: CGPoint; var select: CGPoint
                      var lLabel: CGPoint; var rLabel: CGPoint; var endWidth: CGFloat }
    var twinSpots: TwinSpots {
        let a = controlsArea, u = compactUnit
        let lx = (a.minX + bottom.minX) / 2, rx = (bottom.maxX + a.maxX) / 2
        let y = bottom.midY - u * 0.22
        // L/R are the hinge bar's end segments, like the shoulder buttons of a real clamshell.
        let bar = DualScreenLayout.twinBar(hinge: hinge), ly = bar.midY
        let endW = (a.width * 0.1875).rounded()
        // START / SELECT: round buttons just right of the touch screen's bezel, near its bottom;
        // MENU mirrors SELECT on the left.
        let dotX = bottom.maxX + 22
        return TwinSpots(dpad: CGPoint(x: lx, y: y), face: CGPoint(x: rx, y: y),
                         home: CGPoint(x: bottom.minX - 22 - 18, y: bottom.maxY - 16),
                         start: CGPoint(x: dotX + 27, y: bottom.maxY - 54), select: CGPoint(x: dotX + 27, y: bottom.maxY - 16),
                         lLabel: CGPoint(x: a.minX + endW / 2, y: ly), rLabel: CGPoint(x: a.maxX - endW / 2, y: ly), endWidth: endW)
    }
}

/// Where the in-game buttons go so they never cover a game screen: the two corner groups
/// (touch-only / swap on the left, fast-forward on the right) and the menu button.
struct ChromeSpots: Equatable {
    var left: CGPoint
    var right: CGPoint
    var menu: CGPoint
    /// True when there is no free spot under the screens: the menu sits next to fast-forward.
    var menuBesideRight: Bool
}

extension DualScreenLayout {
    /// `frame`: the safe area the layout lives in (same coordinates as the layout's rects).
    /// `topInset`: the safe-area inset above `frame` (portrait): the corner buttons sit in that
    /// band, beside the Dynamic Island, so they take no room from the screens.
    func chromeSpots(in frame: CGRect, topInset: CGFloat = 0, avoid: [CGRect] = [], cornerWidth: CGFloat = 104, button: CGFloat = 44) -> ChromeSpots {
        let screens = isSingle ? [top] : [top, bottom]
        let scr = screens.dropFirst().reduce(screens[0]) { $0.union($1) }
        let half = button / 2
        let outer = CGRect(x: frame.minX, y: frame.minY - topInset, width: frame.width, height: frame.height + topInset)
        var left = CGPoint(x: frame.minX + 8 + cornerWidth / 2, y: frame.minY + half)
        var right = CGPoint(x: frame.maxX - 8 - half - 4, y: frame.minY + half)
        let gutterL = scr.minX - frame.minX, gutterR = frame.maxX - scr.maxX
        if isPortrait {
            // The very top corners of the shell: inside the top inset when there is one.
            let y = outer.minY + max(Self.topBand / 2, topInset / 2 + 2)
            left.y = y; right.y = y
        } else if gutterL >= cornerWidth + 8 && gutterR >= button + 8 {
            // Landscape: top of the side gutters, beside the screens.
            left = CGPoint(x: frame.minX + gutterL / 2, y: frame.minY + half)
            right = CGPoint(x: frame.maxX - gutterR / 2, y: frame.minY + half)
        }
        func free(_ c: CGPoint) -> Bool {
            let r = CGRect(x: c.x - half - 4, y: c.y - half, width: button + 8, height: button)
            return outer.insetBy(dx: -1, dy: -1).contains(r) && !screens.contains { $0.intersects(r) } && !avoid.contains { $0.intersects(r) }
        }
        // Menu: under the screens first (centre, then shifted), then the strip above, then beside FF.
        let lowest = screens.map(\.maxY).max() ?? scr.maxY
        // Prefer clearing the drawn bezel (14pt) and fall back to hugging the screen edge.
        let yb = lowest + half + 2
        var candidates = [CGPoint(x: scr.midX, y: lowest + half + 14), CGPoint(x: scr.midX, y: yb)]
        for dx in stride(from: button + 10, through: frame.width / 2 - button, by: button / 2) {
            candidates += [CGPoint(x: scr.midX - dx, y: yb), CGPoint(x: scr.midX + dx, y: yb)]
        }
        for c in candidates where free(c) {
            return ChromeSpots(left: left, right: right, menu: c, menuBesideRight: false)
        }
        if isPortrait, free(CGPoint(x: top.midX, y: left.y)) {
            return ChromeSpots(left: left, right: right, menu: CGPoint(x: top.midX, y: left.y), menuBesideRight: false)
        }
        return ChromeSpots(left: left, right: right, menu: right, menuBesideRight: true)
    }
}


extension DualScreenLayout {
    /// Closed iPhone Duo outer display, landscape, single-screen games: a full-bleed handheld
    /// shell. The screen is centred and takes most of the height, the D-pad sits bottom-left,
    /// A/B on the right, small SELECT/START centred under the screen bezel, a MENU pill top-left
    /// and a speaker grille top-right (GBA adds L/R shoulder pills in the top corners).
    static func makeOuter(size: CGSize, aspect: CGFloat, gba: Bool) -> DualScreenLayout {
        let w = size.width, h = size.height
        if h > w { return makeOuterPortrait(size: size, aspect: aspect, gba: gba) }
        let m = h * 0.034
        // Bezel: centred, wide, in the upper/middle area; the bottom strip holds the controls.
        let bandTop: CGFloat = 10, bandBottom = h - 104
        let maxSW = w * 0.59 - m * 2, maxSH = bandBottom - bandTop - m * 2.9
        let sw = min(maxSW, maxSH * aspect), sh = sw / aspect
        let bezelH = sh + m * 2.9
        let y0 = bandTop + (bandBottom - bandTop - bezelH) / 2 + m
        let top = CGRect(x: w / 2 - sw / 2, y: y0, width: sw, height: sh)
        var l = DualScreenLayout(top: top, bottom: .zero, isPortrait: false, isSideBySide: false,
                                 controlsArea: CGRect(origin: .zero, size: size), isSingle: true)
        l.outer = true
        l.outerGBA = gba
        return l
    }

    /// Portrait outer display, like an original Game Boy: screen at the top, D-pad lower-left,
    /// A/B lower-right on a diagonal, SELECT/START centred below them.
    static func makeOuterPortrait(size: CGSize, aspect: CGFloat, gba: Bool) -> DualScreenLayout {
        let w = size.width, h = size.height
        let m = min(w, h) * 0.034
        let sw0 = w - 56 - m * 2
        let sh = min(sw0 / aspect, h * 0.44), sw = sh * aspect
        let top = CGRect(x: w / 2 - sw / 2, y: 74 + m, width: sw, height: sh)
        var l = DualScreenLayout(top: top, bottom: .zero, isPortrait: true, isSideBySide: false,
                                 controlsArea: CGRect(origin: .zero, size: size), isSingle: true)
        l.outer = true
        l.outerGBA = gba
        return l
    }

    /// The screen bezel (black surround with room for the wordmark under the screen).
    var outerBezel: CGRect {
        let m = min(controlsArea.width, controlsArea.height) * 0.034
        return CGRect(x: top.minX - m, y: top.minY - m, width: top.width + m * 2, height: top.height + m * 2.9)
    }

    /// Corner radius of the outer shell body.
    var outerCornerRadius: CGFloat { min(controlsArea.width, controlsArea.height) * 0.07 }

    struct OuterSpots { var dpad: CGPoint; var face: CGPoint; var unit: CGFloat
                        var select: CGPoint; var start: CGPoint; var menu: CGPoint; var speaker: CGPoint
                        var l: CGRect; var r: CGRect }
    var outerSpots: OuterSpots {
        let w = controlsArea.width, h = controlsArea.height
        let shoulder = CGSize(width: 58, height: 22)
        if h > w {
            // Portrait: controls in the band under the bezel.
            let bz = outerBezel
            let unit = min(w * 0.28, 128)
            let edge: CGFloat = 22
            let band0 = bz.maxY + 14, band1 = h - 64
            let y = max(band0 + unit * 0.5 + 8, (band0 + band1) / 2)
            let face = CGPoint(x: w - edge - unit * 0.62, y: y - unit * 0.04)
            let py = h - 50
            let lr = outerGBA
            return OuterSpots(dpad: CGPoint(x: edge + unit * 0.5 + 6, y: y), face: face, unit: unit,
                              select: CGPoint(x: w / 2 - 36, y: py), start: CGPoint(x: w / 2 + 36, y: py),
                              menu: CGPoint(x: lr ? 28 + shoulder.width + 34 : 52, y: 22),
                              speaker: CGPoint(x: w - 64, y: h - 26),
                              l: CGRect(x: 28, y: 11, width: shoulder.width, height: shoulder.height),
                              r: CGRect(x: w - 96 - shoulder.width, y: 11, width: shoulder.width, height: shoulder.height))
        }
        let bz = outerBezel
        let side = bz.minX                       // room left (and right) of the bezel
        let unit = min(side * 0.72, h * 0.22)
        let lr = outerGBA
        let edge: CGFloat = 20                   // clear margin from the shell edges
        let py = h - 26                          // SELECT/START low in the centre
        // D-pad bottom-left, A/B diagonal near the bottom-right corner.
        let faceX = w - edge - unit * 0.62, faceY = h - edge - unit * 0.62
        return OuterSpots(dpad: CGPoint(x: edge + unit * 0.5 + 4, y: h - edge - unit * 0.5 - 6),
                          face: CGPoint(x: faceX, y: faceY), unit: unit,
                          select: CGPoint(x: w / 2 - 36, y: py), start: CGPoint(x: w / 2 + 36, y: py),
                          menu: CGPoint(x: lr ? 28 + shoulder.width + 34 : max(side * 0.5, 50), y: 22),
                          speaker: CGPoint(x: (bz.maxX + w) / 2, y: bz.midY),   // beside the screen, right side
                          l: CGRect(x: 28, y: 12, width: shoulder.width, height: shoulder.height),
                          r: CGRect(x: w - 28 - shoulder.width, y: 12, width: shoulder.width, height: shoulder.height))
    }
}

// MARK: - Host-side 3DS stacked LCDs (do not change the core present path)

/// Where Azahar's default PortraitTopFullWidth layout already draws the two LCDs
/// inside the visible CAMetalLayer `area`. Matches the pre-layout core
/// (scale_factor 0.8, screen_gap 0, stack shifted so the top LCD is at y = 0).
/// Used only to place skin bezels, controls, and stylus mapping.
enum N3DSHostStackedLayout {
    static func lcds(in area: CGRect, scale: CGFloat) -> (top: CGRect, bottom: CGRect)? {
        guard area.width >= 16, area.height >= 16 else { return nil }
        let px = scale > 0 ? scale : 3
        let fbW = max(16, Int((area.width * px).rounded()))
        let fbH = max(16, Int((area.height * px).rounded()))
        // LargeFrameLayout + PortraitTopFullFrameLayout (not swapped, not upright, gap 0).
        let emuW: Float = 400
        let emuH: Float = 540 // 240 + 0 + 300
        let fit = min(Float(fbW) / emuW, Float(fbH) / emuH)
        let totW = Int(emuW * fit)
        let totH = Int(emuH * fit)
        guard totW >= 16, totH >= 16 else { return nil }
        let left = (fbW - totW) / 2
        let top0 = (fbH - totH) / 2
        let amount = Float(totH) / emuH
        let largeLeft = left
        let largeTop = top0
        let largeRight = Int(400 * amount + Float(left))
        let largeBottom = Int(240 * amount + Float(top0))
        let smallH = Int(300 * amount + Float(top0)) - top0
        let largeH = largeBottom - largeTop
        // BelowLarge, then shiftY so the top of the stack is at y = 0.
        let shift = -largeTop
        let topPx = CGRect(x: CGFloat(largeLeft),
                           y: CGFloat(largeTop + shift),
                           width: CGFloat(max(1, largeRight - largeLeft)),
                           height: CGFloat(max(1, largeH)))
        let botPx = CGRect(x: CGFloat(largeLeft),
                           y: CGFloat(largeTop + largeH + shift),
                           width: CGFloat(max(1, largeRight - largeLeft)),
                           height: CGFloat(max(1, smallH)))
        func pt(_ r: CGRect) -> CGRect {
            CGRect(x: area.minX + r.minX / px,
                   y: area.minY + r.minY / px,
                   width: r.width / px,
                   height: r.height / px)
        }
        let top = pt(topPx)
        let bot = pt(botPx)
        guard top.width >= 8, top.height >= 8, bot.width >= 8, bot.height >= 8 else { return nil }
        return (top, bot)
    }
}

