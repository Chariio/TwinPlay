// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import XCTest
#if canImport(SwiftUI)
import SwiftUI
#endif
@testable import TwinPlay

/// #22 Heritage pack: classic-handheld shells for every system, free, grouped first in the
/// picker, no third-party names in the labels, controls kept off the screens in every layout.
final class HeritageSkinTests: XCTestCase {
    private var heritage: [Skin] { Skin.allCases.filter(\.isHeritage) }

    func testPackContents() {
        XCTAssertEqual(heritage.count, 17)
        for s in heritage { XCTAssertTrue(s.isFree, "\(s)") }
        let ds = heritage.filter { $0.systems == [.ds] }, single = heritage.filter { $0.systems == [.gba] }
        XCTAssertEqual(Set(ds), [.heritagePhatPlatinum, .heritagePhatOnyx, .heritageCamBlack, .heritageCamWhite])
        XCTAssertEqual(ds.count + single.count, heritage.count)
        XCTAssertEqual(Skin.heritageBrick.shellStyle, .brick); XCTAssertEqual(Skin.heritageBrick.padModel, .brick)
        XCTAssertEqual(Skin.heritageColorKiwi.shellStyle, .color)
        XCTAssertEqual(Skin.heritageWideGlacier.shellStyle, .gba); XCTAssertTrue(Skin.heritageWideGlacier.lid.translucent)
        XCTAssertTrue(Skin.heritageColorAtomic.lid.translucent)
        XCTAssertEqual(Skin.heritageFlipCobalt.shellStyle, .clamshell)
        for s in ds { XCTAssertEqual(s.shellStyle, .twin) }       // keeps the DS reference geometry (Duo, iPad)
        XCTAssertEqual(Skin.heritagePhatOnyx.padModel, .phat)
    }

    func testNoThirdPartyNames() {
        let banned = ["nintendo", "game boy", "gameboy", "advance", "dsi", "ds ", " ds", "pokemon", "pokémon"]
        for s in heritage {
            let l = s.label.lowercased()
            for b in banned { XCTAssertFalse(l.contains(b), "\(s.label) contains \(b)") }
        }
    }

    #if canImport(SwiftUI) && os(iOS)
    func testPickerGroupsHeritageFirst() {
        for sys in [GameSystem.ds, .gba] {
            let g = SkinPickerView.groups(for: sys)
            XCTAssertEqual(g.first?.title, "Heritage")
            XCTAssertTrue(g[0].skins.allSatisfy(\.isHeritage))
            XCTAssertEqual(Set(g.flatMap(\.skins)), Set(Skin.skins(for: sys)))
        }
    }

    // MARK: layouts used by the game view

    enum Scene: String, CaseIterable { case phone, phoneLandscape, duoOpen, duoOuter, ipad }

    struct Built { let layout: DualScreenLayout; let size: CGSize; let frame: CGRect; let topInset: CGFloat }

    static func build(_ scene: Scene, skin: Skin) -> Built? {
        let ds = skin.systems.contains(.ds)
        let gb = skin.shellStyle == .brick || skin.shellStyle == .color
        let aspect: CGFloat = gb ? 160.0 / 144.0 : 1.5
        let margin: CGFloat = gb ? 40 : 12
        switch scene {
        case .phone:
            let full = CGSize(width: 440, height: 956), ti: CGFloat = 62
            let frame = CGRect(x: 0, y: ti, width: full.width, height: full.height - ti - 34)
            let r = DualScreenLayout.topReserve(forInset: ti)
            let l = ds ? DualScreenLayout.make(size: frame.size, arrangement: .automatic, showsControls: true, topReserve: r)
                       : DualScreenLayout.makeSingle(size: frame.size, showsControls: true, aspect: aspect, portraitMargin: margin, topReserve: r)
            return Built(layout: l.offsetBy(dx: frame.minX, dy: frame.minY), size: full, frame: frame, topInset: ti)
        case .phoneLandscape:
            let full = CGSize(width: 956, height: 440)
            let frame = CGRect(x: 62, y: 0, width: full.width - 124, height: full.height - 21)
            let l = ds ? DualScreenLayout.make(size: frame.size, arrangement: .automatic, showsControls: true)
                       : DualScreenLayout.makeSingle(size: frame.size, showsControls: true, aspect: aspect, portraitMargin: margin)
            return Built(layout: l.offsetBy(dx: frame.minX, dy: frame.minY), size: full, frame: frame, topInset: 0)
        case .duoOpen:
            let full = CGSize(width: 669, height: 951)
            let safe = CGRect(x: 0, y: 24, width: full.width, height: full.height - 44)
            let l = DualScreenLayout.makeFolded(safe: safe, hinge: FoldGeometry.defaultHinge(full: full), posture: .open, isGBA: !ds,
                                                showsControls: true, gbaAspect: aspect, twin: skin.shellStyle == .twin)
            return Built(layout: l, size: full, frame: safe, topInset: 0)
        case .duoOuter:
            guard !ds else { return nil }
            let full = CGSize(width: 678, height: 466)
            return Built(layout: DualScreenLayout.makeOuter(size: full, aspect: aspect, gba: !gb), size: full, frame: CGRect(origin: .zero, size: full), topInset: 0)
        case .ipad:
            let full = CGSize(width: 1032, height: 1376), ti: CGFloat = 24
            let frame = CGRect(x: 0, y: ti, width: full.width, height: full.height - ti - 20)
            if ds, let ref = DualScreenLayout.makeReference(frame: frame) { return Built(layout: ref, size: full, frame: frame, topInset: ti) }
            let l = ds ? DualScreenLayout.make(size: frame.size, arrangement: .automatic, showsControls: true)
                       : DualScreenLayout.makeSingle(size: frame.size, showsControls: true, aspect: aspect, portraitMargin: margin)
            return Built(layout: l.offsetBy(dx: frame.minX, dy: frame.minY), size: full, frame: frame, topInset: ti)
        }
    }

    static func pad(_ b: Built, skin: Skin) -> TouchPadLayout {
        let ds = skin.systems.contains(.ds)
        let sys: PadSystem = ds ? .ds : (skin.shellStyle == .brick || skin.shellStyle == .color ? .gameBoy : .gba)
        return TouchPadLayout.make(layout: b.layout, system: sys, showsButtons: true, scale: 1,
                                   stylus: ds && !b.layout.isSingle ? b.layout.bottom : nil, model: skin.padModel)
    }

    static func menuSpot(_ b: Built, pad: TouchPadLayout) -> CGPoint {
        let l = b.layout
        if l.outer { return l.outerSpots.menu }
        if l.twin { return l.twinSpots.home }
        let spots = l.chromeSpots(in: b.frame, topInset: b.frame.height >= b.frame.width ? b.topInset : 0, avoid: pad.zones.map(\.hit))
        let scr = l.isSingle ? l.top : l.top.union(l.bottom)
        let narrow = b.frame.maxX - scr.maxX < 104
        return spots.menuBesideRight ? CGPoint(x: spots.right.x - (narrow ? 0 : 54), y: spots.right.y + (narrow ? 50 : 0)) : spots.menu
    }

    func testControlsOffScreensInEveryLayout() {
        for skin in heritage {
            for scene in Scene.allCases {
                guard let b = Self.build(scene, skin: skin) else { continue }
                let pad = Self.pad(b, skin: skin)
                XCTAssertFalse(pad.zones.isEmpty, "\(skin) \(scene)")
                let screens = b.layout.isSingle ? [b.layout.top] : [b.layout.top, b.layout.bottom]
                let bounds = CGRect(origin: .zero, size: b.size)
                for z in pad.zones {
                    XCTAssertTrue(bounds.insetBy(dx: -1, dy: -1).contains(z.rect), "\(skin) \(scene) \(z.label) outside")
                    for s in screens where scene != .phoneLandscape || !skin.systems.contains(.ds) {
                        XCTAssertFalse(z.rect.insetBy(dx: 2, dy: 2).intersects(s), "\(skin) \(scene) \(z.label) on screen")
                    }
                }
                let m = Self.menuSpot(b, pad: pad)
                XCTAssertTrue(bounds.contains(m), "\(skin) \(scene) MENU outside")
                for s in screens { XCTAssertFalse(s.contains(m), "\(skin) \(scene) MENU on screen") }
            }
        }
    }

    // MARK: previews

    /// Homebrew-style test picture (no game artwork): 4-shade bars for the brick, colour bars otherwise.
    struct TestScreen: View {
        let brick: Bool
        var body: some View {
            GeometryReader { g in
                let shades: [Color] = brick
                    ? [Color(red: 0.61, green: 0.74, blue: 0.06), Color(red: 0.55, green: 0.67, blue: 0.06), Color(red: 0.19, green: 0.38, blue: 0.19), Color(red: 0.06, green: 0.22, blue: 0.06)]
                    : [Color(red: 0.95, green: 0.35, blue: 0.35), Color(red: 1, green: 0.8, blue: 0.25), Color(red: 0.35, green: 0.8, blue: 0.45), Color(red: 0.3, green: 0.55, blue: 1), Color(red: 0.6, green: 0.4, blue: 0.9)]
                ZStack {
                    (brick ? shades[0] : Color(red: 0.08, green: 0.1, blue: 0.2))
                    VStack(spacing: 0) {
                        HStack(spacing: 0) { ForEach(0..<shades.count, id: \.self) { i in shades[i] } }.frame(height: g.size.height * 0.28)
                        Spacer()
                    }
                    Text("TwinPlay").font(.system(size: max(10, g.size.height * 0.13), weight: .black, design: .rounded))
                        .foregroundStyle(brick ? shades[3] : .white).offset(y: g.size.height * 0.12)
                }
            }
        }
    }

    @MainActor static func render(_ skin: Skin, _ scene: Scene) -> UIImage? {
        guard let b = build(scene, skin: skin) else { return nil }
        let l = b.layout
        let pad = pad(b, skin: skin)
        let brick = skin.shellStyle == .brick
        let v = ZStack(alignment: .topLeading) {
            SkinBackground(layout: l, size: b.size)
            ForEach(l.isSingle ? [l.top] : [l.top, l.bottom], id: \.minY) { r in
                TestScreen(brick: brick).frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
            }
            ControlsOverlay(pad: pad, state: PadVisualState(), opacity: 1)
            MenuPill(darkBody: MenuPill.isDark(skin.palette), round: l.twin ? skin.palette : nil).position(menuSpot(b, pad: pad))
        }
        .frame(width: b.size.width, height: b.size.height)
        .background(SkinSurround(skin: skin))
        .environment(\.skin, skin)
        let r = ImageRenderer(content: v); r.scale = 2
        return r.uiImage
    }

    /// Set TWINPLAY_RENDER_DIR to write heritage-<skin>-<scene>.png for every Heritage skin and layout.
    @MainActor func testRenderHeritage() throws {
        guard let dir = ProcessInfo.processInfo.environment["TWINPLAY_RENDER_DIR"] else { throw XCTSkip("no render dir") }
        for skin in heritage {
            for scene in Scene.allCases {
                guard let img = Self.render(skin, scene) else { continue }
                try XCTUnwrap(img.pngData()).write(to: URL(fileURLWithPath: dir).appendingPathComponent("heritage-\(skin.rawValue)-\(scene.rawValue).png"))
            }
        }
    }
    #endif
}
