// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import XCTest
import SwiftUI
@testable import TwinPlay

/// On-screen controls: D-pad sectors, sliding between buttons, A+B, multitouch, the DS touch
/// screen alongside the buttons, and layouts that keep 44pt targets off the game screens.
final class TouchControlsTests: XCTestCase {
    // iPhone 17/18 Pro Max class sizes (points), safe area already removed.
    private let portrait = CGSize(width: 440, height: 860)
    private let landscape = CGSize(width: 830, height: 420)

    private func pad(_ size: CGSize, _ sys: PadSystem, buttons: Bool = true, scale: CGFloat = 1) -> TouchPadLayout {
        let l: DualScreenLayout
        switch sys {
        case .ds: l = DualScreenLayout.make(size: size, arrangement: .automatic, showsControls: buttons)
        case .gba: l = DualScreenLayout.makeSingle(size: size, showsControls: buttons)
        case .gameBoy: l = DualScreenLayout.makeSingle(size: size, showsControls: buttons, aspect: 160.0 / 144.0)
        case .nes: l = DualScreenLayout.makeSingle(size: size, showsControls: buttons, aspect: 256.0 / 240.0)
        case .snes: l = DualScreenLayout.makeSingle(size: size, showsControls: buttons, aspect: 256.0 / 224.0)
        }
        return TouchPadLayout.make(layout: l, system: sys, showsButtons: buttons, scale: scale, stylus: sys == .ds ? l.bottom : nil)
    }

    private func zone(_ p: TouchPadLayout, _ b: DSButton) -> PadZone { p.zones.first { $0.button == b }! }
    private func centre(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }

    // MARK: D-pad

    func testDPadEightWayAndDeadZone() {
        XCTAssertEqual(DPadMath.directions(dx: 3, dy: 2, deadZone: 8), [])
        XCTAssertEqual(DPadMath.directions(dx: 30, dy: 0, deadZone: 8), .right)
        XCTAssertEqual(DPadMath.directions(dx: 0, dy: -30, deadZone: 8), .up)
        XCTAssertEqual(DPadMath.directions(dx: 30, dy: -30, deadZone: 8), [.up, .right])
        XCTAssertEqual(DPadMath.directions(dx: -30, dy: 30, deadZone: 8), [.down, .left])
        // 20° off the axis is still a clean cardinal (forgiving for running in a line).
        XCTAssertEqual(DPadMath.directions(dx: cos(20 * .pi / 180) * 30, dy: -sin(20 * .pi / 180) * 30, deadZone: 8), .right)
    }

    func testDPadHysteresisHoldsTheCurrentDirection() {
        let a: CGFloat = 29 * .pi / 180                       // just past the 27.5° cardinal edge
        let p = (dx: cos(a) * 30, dy: -sin(a) * 30)
        XCTAssertEqual(DPadMath.directions(dx: p.dx, dy: p.dy, deadZone: 8), [.up, .right])
        XCTAssertEqual(DPadMath.directions(dx: p.dx, dy: p.dy, deadZone: 8, current: .right), .right)
        // Inside the dead zone once pressed: holds until well inside the centre.
        XCTAssertEqual(DPadMath.directions(dx: 7, dy: 0, deadZone: 8, current: .right), .right)
        XCTAssertEqual(DPadMath.directions(dx: 4, dy: 0, deadZone: 8, current: .right), [])
    }

    func testDPadSlidesBetweenDirectionsWithoutLifting() {
        var r = PadTouchResolver(layout: pad(portrait, .ds))
        let d = zone(r.layout, [.up, .down, .left, .right]).rect
        r.began(1, at: CGPoint(x: d.maxX - 5, y: d.midY))
        XCTAssertEqual(r.pressed, .right)
        r.moved(1, to: CGPoint(x: d.maxX - 5, y: d.minY + 5))
        XCTAssertEqual(r.pressed, [.up, .right])
        r.moved(1, to: CGPoint(x: d.midX, y: d.minY + 5))
        XCTAssertEqual(r.pressed, .up)
        r.moved(1, to: CGPoint(x: d.minX - 30, y: d.midY))         // far outside: still owned by the pad
        XCTAssertEqual(r.pressed, .left)
        r.ended(1)
        XCTAssertEqual(r.pressed, [])
    }

    // MARK: Buttons

    func testSlideFromAToBAndChord() {
        for sys in [PadSystem.ds, .gba, .gameBoy] {
            var r = PadTouchResolver(layout: pad(portrait, sys))
            let a = zone(r.layout, .a).rect, b = zone(r.layout, .b).rect
            r.began(1, at: centre(a))
            XCTAssertEqual(r.pressed, .a, "\(sys)")
            let mid = CGPoint(x: (a.midX + b.midX) / 2, y: (a.midY + b.midY) / 2)
            r.moved(1, to: mid)
            XCTAssertEqual(r.pressed, [.a, .b], "\(sys): between A and B presses both")
            r.moved(1, to: centre(b))
            XCTAssertEqual(r.pressed, .b, "\(sys): slid onto B")
            r.ended(1)
            // Landing between them is A+B straight away.
            r.began(2, at: mid)
            XCTAssertEqual(r.pressed, [.a, .b], "\(sys)")
            r.ended(2)
        }
    }

    func testInvisibleMarginAndNearestButton() {
        var r = PadTouchResolver(layout: pad(portrait, .gba))
        let a = zone(r.layout, .a)
        // Just outside the drawn circle, inside the margin.
        r.began(1, at: CGPoint(x: a.rect.maxX + 4, y: a.rect.midY))
        XCTAssertEqual(r.pressed, .a)
    }

    func testStartSelectNeedADirectTap() {
        var r = PadTouchResolver(layout: pad(portrait, .ds))
        let start = zone(r.layout, .start).rect
        r.began(1, at: CGPoint(x: start.midX, y: start.minY - 60))  // empty space
        r.moved(1, to: centre(start))
        XCTAssertEqual(r.pressed, [], "a sliding finger never presses Start")
        r.ended(1)
        r.began(2, at: centre(start))
        XCTAssertEqual(r.pressed, .start)
    }

    func testMultitouchDPadPlusTwoButtons() {
        var r = PadTouchResolver(layout: pad(landscape, .ds))
        let d = zone(r.layout, [.up, .down, .left, .right]).rect
        r.began(1, at: CGPoint(x: d.midX, y: d.minY + 4))
        r.began(2, at: centre(zone(r.layout, .a).rect))
        r.began(3, at: centre(zone(r.layout, .r).rect))
        XCTAssertEqual(r.pressed, [.up, .a, .r])
        r.ended(2)
        XCTAssertEqual(r.pressed, [.up, .r])
        XCTAssertEqual(r.activeFingers, 2)
    }

    // MARK: DS touch screen

    func testStylusAlongsideButtons() {
        var r = PadTouchResolver(layout: pad(portrait, .ds))
        let st = r.layout.stylus!
        r.began(1, at: centre(zone(r.layout, .a).rect))
        XCTAssertTrue(r.began(2, at: CGPoint(x: st.midX, y: st.midY)))
        XCTAssertTrue(r.isStylus(2))
        XCTAssertEqual(r.pressed, .a, "the stylus never presses buttons")
        XCTAssertFalse(r.began(3, at: CGPoint(x: st.midX + 20, y: st.midY)), "one stylus at a time")
        r.ended(2)
        XCTAssertTrue(r.began(4, at: CGPoint(x: st.minX - 3, y: st.minY - 3)), "edge pixels are reachable")
    }

    func testStylusMappingAndClamping() {
        let rect = CGRect(x: 10, y: 400, width: 512, height: 384)     // 2x scale
        XCTAssertTrue(StylusMapper.map(CGPoint(x: 10, y: 400), in: rect) == (0, 0))
        XCTAssertTrue(StylusMapper.map(CGPoint(x: 521.9, y: 783.9), in: rect) == (255, 191))
        XCTAssertTrue(StylusMapper.map(CGPoint(x: 10 + 2 * 100 + 1, y: 400 + 2 * 50 + 1), in: rect) == (100, 50))
        XCTAssertTrue(StylusMapper.map(CGPoint(x: -50, y: 2000), in: rect) == (0, 191), "dragging off clamps, never drops")
        XCTAssertTrue(StylusMapper.map(CGPoint(x: 10 + 200, y: 400 + 124), in: rect, raise: 24) == (100, 50))
        for (x, y) in [(0, 0), (128, 96), (255, 191)] {
            let p = StylusMapper.point(x: x, y: y, in: rect)
            XCTAssertTrue(StylusMapper.map(p, in: rect) == (x, y))
        }
    }

    func testButtonMarginsNeverReachIntoTheTouchScreen() {
        for size in [portrait, landscape] {
            let p = pad(size, .ds)
            for z in p.zones { XCTAssertFalse(z.hit.intersects(p.stylus!.insetBy(dx: 1, dy: 1)), "\(z.label) \(size)") }
        }
    }

    // MARK: Layouts

    func testTargetsAreAtLeast44pt() {
        for size in [portrait, landscape] {
            for sys in [PadSystem.ds, .gba, .gameBoy] {
                for scale: CGFloat in [0.8, 1, 1.3] {
                    for z in pad(size, sys, scale: scale).zones {
                        let side = z.hitRadius.map { $0 * 2 } ?? min(z.hit.width, z.hit.height)
                        XCTAssertGreaterThanOrEqual(side, 44, "\(sys) \(size) \(z.label)")
                    }
                }
            }
        }
    }

    func testLandscapeControlsNeverCoverTheGame() {
        for size in [landscape, CGSize(width: 780, height: 360), CGSize(width: 900, height: 410)] {
            for sys in [PadSystem.ds, .gba, .gameBoy] {
                let p = pad(size, sys)
                for z in p.zones { for s in p.screens { XCTAssertFalse(z.rect.intersects(s), "\(sys) \(size) \(z.label)") } }
            }
        }
    }

    func testPortraitControlsStayBelowTheScreensAndApart() {
        for sys in [PadSystem.ds, .gba, .gameBoy] {
            let p = pad(portrait, sys, scale: 1.3)
            for z in p.zones { for s in p.screens { XCTAssertFalse(z.rect.intersects(s), "\(sys) \(z.label)") } }
            for i in p.zones.indices { for j in p.zones.indices where j > i {
                let a = p.zones[i], b = p.zones[j]
                let overlap = a.shape == .circle && b.shape == .circle
                    ? hypot(a.rect.midX - b.rect.midX, a.rect.midY - b.rect.midY) < (a.rect.width + b.rect.width) / 2
                    : a.rect.intersects(b.rect)
                XCTAssertFalse(overlap, "\(sys) \(a.label)/\(b.label)")
            } }
            XCTAssertEqual(p.zones.contains { $0.button == .l }, sys != .gameBoy)
        }
    }

    func testTouchOnlyLeavesTheScreensFree() {
        for size in [portrait, landscape] {
            let p = pad(size, .ds, buttons: false)
            XCTAssertFalse(p.zones.contains { $0.isDPad || $0.button == .a })
            for z in p.zones { for s in p.screens { XCTAssertFalse(z.rect.intersects(s)) } }
            var r = PadTouchResolver(layout: p)
            let st = p.stylus!
            XCTAssertTrue(r.began(1, at: CGPoint(x: st.midX, y: st.maxY - 2)), "the whole bottom screen is touchable")
        }
    }

    func testTwinOpenCompactLayout() {
        let full = CGSize(width: 760, height: 1000)
        let l = DualScreenLayout.makeFolded(safe: CGRect(x: 0, y: 40, width: 760, height: 940),
                                            hinge: FoldGeometry.defaultHinge(full: full), posture: .open,
                                            isGBA: false, showsControls: true)
        XCTAssertGreaterThan(l.compactUnit, 0)
        let p = TouchPadLayout.make(layout: l, system: .ds, showsButtons: true, stylus: l.bottom)
        for z in p.zones {
            XCTAssertFalse(z.rect.intersects(l.bottom), z.label)
            XCTAssertFalse(z.hit.intersects(l.bottom.insetBy(dx: 1, dy: 1)), z.label)
        }
        var r = PadTouchResolver(layout: p)
        r.began(1, at: centre(zone(p, .a).rect))
        XCTAssertTrue(r.began(2, at: centre(l.bottom)))
        XCTAssertEqual(r.pressed, .a)
    }

    func testTwinPearlShellLayout() {
        // iPhone Duo-like display, fully open: pearl shell presentation.
        let full = CGSize(width: 760, height: 1000)
        let hinge = FoldGeometry.defaultHinge(full: full)
        let l = DualScreenLayout.makeFolded(safe: CGRect(x: 0, y: 40, width: 760, height: 940), hinge: hinge,
                                            posture: .open, isGBA: false, showsControls: true, twin: true)
        XCTAssertTrue(l.twin)
        let bar = DualScreenLayout.twinBar(hinge: hinge)
        // Screens never touch the fold / hinge bar, one in each half, same size, centred.
        XCTAssertFalse(l.top.intersects(bar)); XCTAssertFalse(l.bottom.intersects(bar))
        XCTAssertLessThan(l.top.maxY, bar.minY); XCTAssertGreaterThan(l.bottom.minY, bar.maxY)
        XCTAssertEqual(l.top.width, l.bottom.width, accuracy: 0.5)
        XCTAssertEqual(l.top.midX, full.width / 2, accuracy: 1)
        XCTAssertGreaterThan(l.top.width, 300)
        let p = TouchPadLayout.make(layout: l, system: .ds, showsButtons: true, stylus: l.bottom)
        for z in p.zones {
            XCTAssertFalse(z.rect.intersects(l.bottom) || z.rect.intersects(l.top), z.label)
            // L and R sit on the hinge bar's ends (like the photo); nothing else goes on the fold.
            if z.label != "L" && z.label != "R" { XCTAssertFalse(z.rect.intersects(bar), z.label) } else { XCTAssertTrue(bar.contains(CGPoint(x: z.rect.midX, y: z.rect.midY)), z.label) }
            XCTAssertTrue(CGRect(origin: .zero, size: full).contains(z.rect), z.label)
        }
        // D-pad left of the touch screen, face buttons right, START above SELECT on the right.
        XCTAssertLessThan(p.zones.first { $0.shape == .dpad }!.rect.maxX, l.bottom.minX)
        XCTAssertGreaterThan(zone(p, .a).rect.minX, l.bottom.maxX)
        XCTAssertLessThan(zone(p, .start).rect.midY, zone(p, .select).rect.midY)
        XCTAssertGreaterThan(zone(p, .start).rect.minX, l.bottom.maxX)
        // Stylus still works on the touch screen.
        var r = PadTouchResolver(layout: p)
        XCTAssertTrue(r.began(1, at: centre(l.bottom)))
    }

    func testLayoutChangeReleasesButtonsButKeepsTheStylus() {
        var r = PadTouchResolver(layout: pad(portrait, .ds))
        r.began(1, at: centre(zone(r.layout, .a).rect))
        r.began(2, at: centre(r.layout.stylus!))
        r.setLayout(pad(portrait, .ds, scale: 1.15))
        XCTAssertEqual(r.pressed, [])
        XCTAssertTrue(r.isStylus(2))
    }

    // MARK: Per-model placement

    func testModelPlacementsStayClearAndReachable() {
        for model in [PadModel.standard, .phat, .brick] {
            for sys in [PadSystem.ds, .gba, .gameBoy] {
                let l: DualScreenLayout = sys == .ds ? DualScreenLayout.make(size: portrait, arrangement: .automatic, showsControls: true)
                                                     : DualScreenLayout.makeSingle(size: portrait, showsControls: true)
                let p = TouchPadLayout.make(layout: l, system: sys, showsButtons: true, stylus: sys == .ds ? l.bottom : nil, model: model)
                for z in p.zones {
                    XCTAssertGreaterThanOrEqual(z.hit.width, 44, "\(model) \(z.label)")
                    XCTAssertGreaterThanOrEqual(z.hit.height, 44, "\(model) \(z.label)")
                    XCTAssertFalse(p.screens.contains { $0.intersects(z.rect) }, "\(model) \(sys) \(z.label) covers a screen")
                }
                // Drawn controls never overlap each other.
                for (i, a) in p.zones.enumerated() { for b in p.zones[(i + 1)...] {
                    let overlap: Bool
                    if a.shape == .circle && b.shape == .circle {
                        overlap = hypot(a.rect.midX - b.rect.midX, a.rect.midY - b.rect.midY) < (a.rect.width + b.rect.width) / 2 - 1
                    } else { overlap = a.rect.insetBy(dx: 1, dy: 1).intersects(b.rect.insetBy(dx: 1, dy: 1)) }
                    XCTAssertFalse(overlap, "\(model) \(sys) \(a.label)/\(b.label)")
                } }
            }
        }
        // Every model: Start/Select at the very bottom, below the face buttons.
        for model in [PadModel.standard, .phat, .brick] {
            let l = DualScreenLayout.make(size: portrait, arrangement: .automatic, showsControls: true)
            let p = TouchPadLayout.make(layout: l, system: .ds, showsButtons: true, stylus: l.bottom, model: model)
            XCTAssertGreaterThan(zone(p, .start).rect.minY, zone(p, .b).rect.maxY)
            XCTAssertGreaterThan(zone(p, .select).rect.minY, zone(p, .b).rect.maxY)
        }
    }

    // MARK: In-game buttons (touch-only, menu, fast-forward) never cover a game screen

    /// Layouts as the app builds them: `inset` is the top safe-area inset (59 = Dynamic Island, 0 = none).
    private func appLayout(_ sys: PadSystem, size: CGSize, inset: CGFloat) -> (DualScreenLayout, CGRect) {
        let portraitMode = size.height >= size.width
        let frame = CGRect(x: 0, y: portraitMode ? inset : 0, width: size.width, height: size.height - (portraitMode ? inset + 34 : 0))
        let reserve = portraitMode ? DualScreenLayout.topReserve(forInset: inset) : 0
        let l: DualScreenLayout
        switch sys {
        case .ds: l = DualScreenLayout.make(size: frame.size, arrangement: .automatic, showsControls: true, topReserve: reserve)
        case .gba: l = DualScreenLayout.makeSingle(size: frame.size, showsControls: true, topReserve: reserve)
        case .gameBoy: l = DualScreenLayout.makeSingle(size: frame.size, showsControls: true, aspect: 160.0 / 144.0, topReserve: reserve)
        case .nes: l = DualScreenLayout.makeSingle(size: frame.size, showsControls: true, aspect: 256.0 / 240.0, topReserve: reserve)
        case .snes: l = DualScreenLayout.makeSingle(size: frame.size, showsControls: true, aspect: 256.0 / 224.0, topReserve: reserve)
        }
        return (l.offsetBy(dx: frame.minX, dy: frame.minY), frame)
    }

    func testChromeButtonsStayOffTheScreens() {
        for inset in [CGFloat(0), 20, 59] {
            for size in [portrait, landscape] {
                for sys in [PadSystem.ds, .gba, .gameBoy] {
                    let (l, frame) = appLayout(sys, size: size, inset: inset)
                    let p = TouchPadLayout.make(layout: l, system: sys, showsButtons: true, stylus: sys == .ds ? l.bottom : nil)
                    let spots = l.chromeSpots(in: frame, topInset: size.height >= size.width ? inset : 0, avoid: p.zones.map(\.hit))
                    let screens = l.isSingle ? [l.top] : [l.top, l.bottom]
                    func box(_ c: CGPoint, _ w: CGFloat = 44) -> CGRect { CGRect(x: c.x - w / 2, y: c.y - 22, width: w, height: 44) }
                    let name = "\(size.width > size.height ? "landscape" : "portrait") \(sys) inset \(inset)"
                    XCTAssertFalse(screens.contains { $0.intersects(box(spots.right)) }, "\(name): fast-forward covers a screen")
                    XCTAssertFalse(screens.contains { $0.intersects(box(spots.left, 98)) }, "\(name): touch-only covers a screen")
                    if !spots.menuBesideRight {
                        XCTAssertFalse(screens.contains { $0.intersects(box(spots.menu, 52)) }, "\(name): menu covers a screen")
                        XCTAssertFalse(p.zones.contains { $0.rect.intersects(box(spots.menu, 52)) }, "\(name): menu covers a control")
                    }
                    if size.height > size.width {
                        // The corner buttons sit in the very top band of the display, not over the game.
                        XCTAssertLessThanOrEqual(spots.left.y, max(DualScreenLayout.topBand, inset) , "\(name): corners not at the top")
                        XCTAssertGreaterThanOrEqual(l.top.minY, spots.left.y + 22, "\(name): top screen under the corner buttons")
                    }
                }
            }
        }
    }

    /// Default layout: no control covers a game screen (the user can still place them anywhere).
    func testDefaultLayoutHasNoControlOverAScreen() {
        for inset in [CGFloat(0), 59] {
            for size in [portrait, landscape] {
                for sys in [PadSystem.ds, .gba, .gameBoy] {
                    let (l, _) = appLayout(sys, size: size, inset: inset)
                    let p = TouchPadLayout.make(layout: l, system: sys, showsButtons: true, stylus: sys == .ds ? l.bottom : nil)
                    let screens = l.isSingle ? [l.top] : [l.top, l.bottom]
                    for z in p.zones {
                        for s in screens {
                            XCTAssertFalse(z.rect.intersects(s), "\(sys) \(size) inset \(inset): \(z.label) covers a screen")
                        }
                    }
                }
            }
        }
    }

    func testPortraitScreensUseTheWholeWidthWhenHeightAllows() {
        // A tall iPhone: the DS screens are no longer shrunk by a reserved strip.
        let (l, frame) = appLayout(.ds, size: CGSize(width: 440, height: 956), inset: 59)
        XCTAssertGreaterThan(l.top.width, 380)
        XCTAssertEqual(l.top.minY, frame.minY, accuracy: 40)       // starts right under the inset
    }
}


/// iPhone Duo fully open with the default Twin · Pearl White shell: screens centred and clear of
/// the hinge, L/R on the hinge bar ends, and (optionally) a rendered preview of the whole face.
@MainActor
final class DuoShellTests: XCTestCase {
    // iPhone Duo inner display, portrait (points).
    private let full = CGSize(width: 669, height: 951)

    private func twinLayout() -> DualScreenLayout {
        let safe = CGRect(x: 0, y: 24, width: full.width, height: full.height - 24 - 20)
        return DualScreenLayout.makeFolded(safe: safe, hinge: FoldGeometry.defaultHinge(full: full), posture: .open,
                                           isGBA: false, showsControls: true, twin: true)
    }

    func testDefaultDSSkinOpenIsTwin() {
        XCTAssertEqual(Skin.twinPearl.shellStyle, .twin)
        XCTAssertTrue(Skin.twinPearl.isFree)
        XCTAssertEqual(Skin.twinBlossom.shellStyle, .twin); XCTAssertEqual(Skin.twinBlossom.isFree, Skin.twinPearl.isFree)
        XCTAssertEqual(GameSystem.ds.defaultSkin, .classicGray)  // open Duo swaps the default to Pearl
    }

    func testTwinLayoutGeometry() {
        let l = twinLayout()
        XCTAssertTrue(l.twin)
        let bar = DualScreenLayout.twinBar(hinge: l.hinge)
        XCTAssertFalse(l.top.intersects(bar)); XCTAssertFalse(l.bottom.intersects(bar))
        XCTAssertEqual(l.top.midX, full.width / 2, accuracy: 1); XCTAssertEqual(l.bottom.midX, full.width / 2, accuracy: 1)
        XCTAssertGreaterThan(l.top.width, full.width * 0.6)
        let sp = l.twinSpots
        XCTAssertEqual(sp.lLabel.y, bar.midY, accuracy: 0.5); XCTAssertEqual(sp.rLabel.y, bar.midY, accuracy: 0.5)
        XCTAssertLessThan(sp.lLabel.x, full.width * 0.15); XCTAssertGreaterThan(sp.rLabel.x, full.width * 0.85)
        let pad = TouchPadLayout.make(layout: l, system: .ds, showsButtons: true, scale: 1, stylus: l.bottom, model: Skin.twinPearl.padModel)
        for z in pad.zones { XCTAssertFalse(z.rect.intersects(l.top) || z.rect.intersects(l.bottom), "\(z)") }
        // Reset (empty customisation) gives back exactly this default.
        XCTAssertEqual(l.applying(CustomLayout(), in: full).top, l.top)
    }

    /// Set TEST_RUNNER_TWINPLAY_RENDER_DIR to write duo-open-twin.png (669x951 pt at 3x).
    func testRenderPreview() throws {
        guard let dir = ProcessInfo.processInfo.environment["TWINPLAY_RENDER_DIR"] else { throw XCTSkip("no render dir") }
        for (skin, name) in [(Skin.twinPearl, "duo-open-twin-pearl.png"), (.twinBlossom, "duo-open-twin-blossom.png")] {
        let l = twinLayout()
        let pad = TouchPadLayout.make(layout: l, system: .ds, showsButtons: true, scale: 1, stylus: l.bottom, model: skin.padModel)
        let v = ZStack(alignment: .topLeading) {
            SkinBackground(layout: l, size: full)
            ForEach([l.top, l.bottom], id: \.minY) { r in
                LinearGradient(colors: [Color(red: 0.2, green: 0.45, blue: 0.9), Color(red: 0.1, green: 0.2, blue: 0.5)], startPoint: .top, endPoint: .bottom)
                    .frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
            }
            ControlsOverlay(pad: pad, state: PadVisualState(), opacity: 1)
        }
        .frame(width: full.width, height: full.height)
        .environment(\.skin, skin)
        let r = ImageRenderer(content: v); r.scale = 3
        let img = try XCTUnwrap(r.uiImage)
        try XCTUnwrap(img.pngData()).write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
    }

    // Closed iPhone Duo, outer display in landscape (678x466pt): classic full-bleed shell.
    func testOuterLandscapeDefault() {
        let full = CGSize(width: 678, height: 466)
        XCTAssertEqual(Skin.outerDefault(for: .gb), .gbClassicGray)
        XCTAssertEqual(Skin.outerDefault(for: .gbc), .gbcGrape)
        XCTAssertEqual(Skin.outerDefault(for: .gba), .gbaIndigo)
        for s in [Skin.gbClassicGray, .gbcGrape, .gbaIndigo] { XCTAssertTrue(s.isFree) }
        for (sys, aspect, gba) in [(PadSystem.gba, 240.0 / 160.0, true), (.gameBoy, 160.0 / 144.0, false)] {
            let l = DualScreenLayout.makeOuter(size: full, aspect: aspect, gba: gba)
            XCTAssertTrue(l.outer && l.isSingle)
            XCTAssertEqual(l.top.midX, full.width / 2, accuracy: 0.5)
            XCTAssertGreaterThan(l.top.height, full.height * 0.5)
            XCTAssertTrue(CGRect(origin: .zero, size: full).contains(l.outerBezel))
            let p = TouchPadLayout.make(layout: l, system: sys, showsButtons: true, stylus: nil)
            let sp = l.outerSpots
            let menu = CGRect(x: sp.menu.x - 20, y: sp.menu.y - 10, width: 40, height: 20)
            let speaker = CGRect(x: sp.speaker.x - 22, y: sp.speaker.y - 14, width: 44, height: 28)
            for z in p.zones {
                XCTAssertFalse(z.rect.intersects(l.outerBezel), z.label)
                XCTAssertTrue(CGRect(origin: .zero, size: full).contains(z.rect), z.label)
                XCTAssertFalse(z.rect.intersects(menu) || z.rect.intersects(speaker), z.label)
            }
            XCTAssertEqual(p.zones.contains { $0.label == "L" }, gba)
            XCTAssertLessThan(p.zones.first { $0.shape == .dpad }!.rect.maxX, l.outerBezel.minX)
            XCTAssertLessThan(sp.select.x, sp.start.x)
            XCTAssertGreaterThan(sp.select.y, l.outerBezel.maxY)
        }
    }

    /// Reset (an empty customisation) returns exactly the closed-Duo default; edits move it.
    func testOuterLandscapeReset() {
        let full = CGSize(width: 678, height: 466)
        let l = DualScreenLayout.makeOuter(size: full, aspect: 1.5, gba: true)
        let p = TouchPadLayout.make(layout: l, system: .gba, showsButtons: true, stylus: nil)
        XCTAssertEqual(l.applying(CustomLayout(), in: full), l)
        XCTAssertEqual(p.applying(CustomLayout(), in: full).zones, p.zones)
        let key = "test.outer.reset"
        let d = UserDefaults(suiteName: "outer-reset-tests")!
        var c = CustomLayout(); c.controls[LayoutControl.allCases[0].rawValue] = ItemPlacement(cx: 0.3, cy: 0.3, size: 1.2)
        LayoutStore.save(c, for: key, defaults: d)
        XCTAssertFalse(LayoutStore.load(key, defaults: d).isEmpty)
        LayoutStore.reset(key, defaults: d)
        XCTAssertTrue(LayoutStore.load(key, defaults: d).isEmpty)
        XCTAssertEqual(l.applying(LayoutStore.load(key, defaults: d), in: full), l)
    }

    /// Closed-Duo shell geometry: every control fully inside the shell
    /// (corners included), the bezel 55-60% wide and nearly full height, pills just under it.
    func testOuterControlsInsideBounds() {
        for full in [CGSize(width: 678, height: 466), CGSize(width: 640, height: 440), CGSize(width: 466, height: 678)] {
            let portrait = full.height > full.width
            for (sys, aspect, gba) in [(PadSystem.gba, 240.0 / 160.0, true), (.gameBoy, 160.0 / 144.0, false)] {
                let l = DualScreenLayout.makeOuter(size: full, aspect: aspect, gba: gba)
                let rad = l.outerCornerRadius
                func inside(_ r: CGRect, margin: CGFloat = 4) -> Bool {
                    let b = CGRect(origin: .zero, size: full).insetBy(dx: margin, dy: margin)
                    guard b.contains(r) else { return false }
                    // Rounded corners: each rect corner must sit inside the corner arc.
                    for p in [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)] {
                        let cx = min(max(p.x, rad), full.width - rad), cy = min(max(p.y, rad), full.height - rad)
                        if hypot(p.x - cx, p.y - cy) > rad - margin { return false }
                    }
                    return true
                }
                let bz = l.outerBezel
                XCTAssertTrue(inside(bz), "bezel")
                if !portrait { XCTAssertGreaterThanOrEqual(bz.width / full.width, gba ? 0.55 : 0.50); XCTAssertLessThanOrEqual(bz.width / full.width, 0.60) }
                XCTAssertEqual(l.top.width / l.top.height, aspect, accuracy: 0.01)
                XCTAssertEqual(bz.midX, full.width / 2, accuracy: 0.5)
                if !portrait { XCTAssertLessThan(bz.maxY, full.height - 90) }
                let p = TouchPadLayout.make(layout: l, system: sys, showsButtons: true, stylus: nil)
                for z in p.zones {
                    XCTAssertTrue(inside(z.rect), "\(z.label) \(z.rect) in \(full)")
                    XCTAssertFalse(z.rect.intersects(bz), z.label)
                }
                let sp = l.outerSpots
                let dpad = p.zones.first { $0.shape == .dpad }!.rect
                XCTAssertGreaterThanOrEqual(dpad.minX, 16); XCTAssertLessThanOrEqual(dpad.maxY, full.height - 16)
                let a = p.zones.first { $0.label == "A" }!.rect, b = p.zones.first { $0.label == "B" }!.rect
                XCTAssertGreaterThan(a.midX, b.midX); XCTAssertLessThan(a.midY, b.midY)
                XCTAssertGreaterThan(b.midY, full.height * 0.6)
                if portrait { XCTAssertGreaterThan(sp.select.y, max(a.maxY, b.maxY, dpad.maxY)); XCTAssertEqual((sp.select.x + sp.start.x) / 2, full.width / 2, accuracy: 0.5) }
                XCTAssertGreaterThan(sp.select.y, bz.maxY); if !portrait { XCTAssertGreaterThan(sp.select.y, full.height * 0.9) }
            }
        }
    }

    /// Closed (or outer-display) iPhone Duo + GB/GBC/GBA in landscape -> classic outer shell.
    func testOuterShellDecision() {
        let land = CGSize(width: 678, height: 466), port = CGSize(width: 466, height: 678)
        let inner = CGSize(width: 669, height: 951), phone = CGSize(width: 440, height: 956)
        XCTAssertTrue(OuterDisplay.isActive(posture: .closed, hingeKnown: true, windowSize: land))
        XCTAssertTrue(OuterDisplay.isActive(posture: .book, hingeKnown: true, windowSize: land))   // tent
        XCTAssertFalse(OuterDisplay.isActive(posture: .open, hingeKnown: true, windowSize: inner))
        XCTAssertFalse(OuterDisplay.isActive(posture: .book, hingeKnown: true, windowSize: CGSize(width: 951, height: 669)))
        XCTAssertFalse(OuterDisplay.isActive(posture: .flat, hingeKnown: false, windowSize: phone))
        XCTAssertFalse(OuterDisplay.isActive(posture: .flat, hingeKnown: false, windowSize: land))  // no hinge: never
        for sys in [GameSystem.gb, .gbc, .gba] {
            XCTAssertTrue(OuterDisplay.usesClassicShell(system: sys, outer: true, size: land))
            XCTAssertTrue(OuterDisplay.usesClassicShell(system: sys, outer: true, size: port))
            XCTAssertFalse(OuterDisplay.usesClassicShell(system: sys, outer: false, size: land))
        }
        XCTAssertFalse(OuterDisplay.usesClassicShell(system: .ds, outer: true, size: land))
    }
}


final class AutoQualityTests: XCTestCase {
    func testStepsDownFastAndUpOnlyWithHeadroom() {
        var s = 0, f = 0
        var r = 0
        for _ in 0..<2 { r = AutoQuality.decide(msPerFrame: 17, autoSkipping: false, fps: 55, frameSkip: 0, active: 2, saved: 2, slowTicks: &s, fastTicks: &f, sinceLastChange: 60, captureInUse: false); XCTAssertEqual(r, 0) }
        r = AutoQuality.decide(msPerFrame: 17, autoSkipping: false, fps: 55, frameSkip: 0, active: 2, saved: 2, slowTicks: &s, fastTicks: &f, sinceLastChange: 60, captureInUse: false)
        XCTAssertEqual(r, -1)                                   // 1.5 s over budget -> down
        s = 0; f = 0
        for _ in 0..<19 { XCTAssertEqual(AutoQuality.decide(msPerFrame: 6, autoSkipping: false, fps: 60, frameSkip: 0, active: 1, saved: 2, slowTicks: &s, fastTicks: &f, sinceLastChange: 60, captureInUse: false), 0) }
        XCTAssertEqual(AutoQuality.decide(msPerFrame: 6, autoSkipping: false, fps: 60, frameSkip: 0, active: 1, saved: 2, slowTicks: &s, fastTicks: &f, sinceLastChange: 60, captureInUse: false), 1)
        s = 0; f = 0                                            // never above the saved setting
        for _ in 0..<30 { XCTAssertEqual(AutoQuality.decide(msPerFrame: 6, autoSkipping: false, fps: 60, frameSkip: 0, active: 2, saved: 2, slowTicks: &s, fastTicks: &f, sinceLastChange: 60, captureInUse: false), 0) }
        s = 0; f = 0                                            // 12 ms: neither slow nor roomy
        for _ in 0..<30 { XCTAssertEqual(AutoQuality.decide(msPerFrame: 12, autoSkipping: false, fps: 60, frameSkip: 0, active: 1, saved: 3, slowTicks: &s, fastTicks: &f, sinceLastChange: 60, captureInUse: false), 0) }
    }
}

import SwiftUI
final class AddGamesLabelTests: XCTestCase {
    /// The Classic DS Menu "+ Add Games" pill stays one line at any width (icon-only when narrow).
    @MainActor func testNeverWraps() {
        for w in [24.0, 40, 60, 90, 140, 400] as [CGFloat] {
            let h = UIHostingController(rootView: AddGamesLabel())
            let s = h.sizeThatFits(in: CGSize(width: w, height: 400))
            XCTAssertLessThanOrEqual(s.height, 36, "width \(w): \(s)")
        }
        let wide = UIHostingController(rootView: AddGamesLabel()).sizeThatFits(in: CGSize(width: 400, height: 400))
        XCTAssertGreaterThan(wide.width, 60)      // full label when there is room
    }
}

final class CheatTests: XCTestCase {
    func testStoreRoundTripAndValidation() {
        let d = UserDefaults(suiteName: "cheat-tests")!; d.removePersistentDomain(forName: "cheat-tests")
        let key = CheatStore.key(system: .gba, gameCode: "", title: "UCITY")
        XCTAssertEqual(key, "cheats.gba.UCITY")
        let list = [CheatEntry(name: "Money", code: "83001000 03E7"), CheatEntry(name: "Off", code: "02000010 000000FF", enabled: false)]
        CheatStore.save(list, key: key, defaults: d)
        XCTAssertEqual(CheatStore.load(key, defaults: d), list)
        XCTAssertNil(DSCoreBridge.cheatError(code: "02000000 12345678", system: "ds"))
        XCTAssertNil(DSCoreBridge.cheatError(code: "010238CD", system: "gb"))
        XCTAssertNil(DSCoreBridge.cheatError(code: "00A-17B-C49", system: "gb"))
        XCTAssertNotNil(DSCoreBridge.cheatError(code: "hello", system: "ds"))
        XCTAssertNotNil(DSCoreBridge.cheatError(code: "9A1B2C3D 1234", system: "gba"))
    }
}
