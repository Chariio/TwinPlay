// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import XCTest
#if canImport(SwiftUI)
import SwiftUI
#endif
@testable import TwinPlay

/// #9 DS skins after ds-skin-ref: open iPhone Duo geometry (L / R on the hinge bar ends, round
/// START / SELECT under the face buttons, MENU left of the touch screen) and every DS colour on
/// the reference shell.
final class DSReferenceSkinTests: XCTestCase {
    private let full = CGSize(width: 669, height: 951)

    private func twin() -> DualScreenLayout {
        let safe = CGRect(x: 0, y: 24, width: full.width, height: full.height - 24 - 20)
        return DualScreenLayout.makeFolded(safe: safe, hinge: FoldGeometry.defaultHinge(full: full), posture: .open,
                                           isGBA: false, showsControls: true, twin: true)
    }

    func testReferenceProportions() {
        let l = twin()
        // Bigger side clusters than before, screens still large.
        XCTAssertGreaterThanOrEqual(l.compactUnit, 100)
        XCTAssertGreaterThan(l.top.width, full.width * 0.6)
        XCTAssertEqual(l.top.width, l.bottom.width, accuracy: 0.5)
        XCTAssertLessThan(l.top.maxY, l.hinge.minY); XCTAssertGreaterThan(l.bottom.minY, l.hinge.maxY)
    }

    func testShouldersAreTheBarEnds() {
        let l = twin()
        let bar = DualScreenLayout.twinBar(hinge: l.hinge)
        let pad = TouchPadLayout.make(layout: l, system: .ds, showsButtons: true, stylus: l.bottom)
        let L = pad.zones.first { $0.button == .l }!, R = pad.zones.first { $0.button == .r }!
        XCTAssertEqual(L.rect.midY, bar.midY, accuracy: 0.5); XCTAssertEqual(R.rect.midY, bar.midY, accuracy: 0.5)
        XCTAssertLessThan(L.rect.maxX, full.width * 0.2); XCTAssertGreaterThan(R.rect.minX, full.width * 0.8)
        XCTAssertGreaterThanOrEqual(L.hit.height, 44)
    }

    func testStartSelectDotsAndMenu() {
        let l = twin()
        let pad = TouchPadLayout.make(layout: l, system: .ds, showsButtons: true, stylus: l.bottom)
        let st = pad.zones.first { $0.button == .start }!, se = pad.zones.first { $0.button == .select }!
        XCTAssertEqual(st.shape, .dot); XCTAssertEqual(se.shape, .dot)
        XCTAssertLessThan(st.rect.midY, se.rect.midY, "START above SELECT")
        XCTAssertGreaterThan(st.rect.minX, l.bottom.maxX); XCTAssertLessThanOrEqual(st.rect.maxX, full.width)
        let faces = pad.zones.filter { $0.shape == .circle }
        for z in [st, se] {
            XCTAssertFalse(z.rect.intersects(l.bottom))
            for f in faces { XCTAssertFalse(z.rect.intersects(f.rect), "\(z.label) vs \(f.label)") }
        }
        let menu = l.twinSpots.home
        XCTAssertLessThan(menu.x, l.bottom.minX); XCTAssertGreaterThan(menu.y, l.bottom.midY)
        let dpad = pad.zones.first { $0.shape == .dpad }!
        XCTAssertFalse(dpad.rect.contains(menu))
    }

    #if canImport(SwiftUI) && os(iOS)
    func testEveryDSColourUsesTheReferenceShell() {
        let ds = Skin.allCases.filter { $0.systems == [.ds] }
        XCTAssertGreaterThanOrEqual(ds.count, 15)
        for s in ds { XCTAssertEqual(s.shellStyle, .twin, "\(s)") }
        XCTAssertTrue(Skin.dsClearIce.lid.translucent); XCTAssertTrue(Skin.dsClearGrape.lid.translucent)
        XCTAssertEqual(Skin.dark.shellStyle, .plain)
    }

    /// Set TWINPLAY_RENDER_DIR to write ds-ref-<skin>.png (open Duo, 669x951 pt at 2x) and the closed lid.
    @MainActor func testRenderReferenceSkins() throws {
        guard let dir = ProcessInfo.processInfo.environment["TWINPLAY_RENDER_DIR"] else { throw XCTSkip("no render dir") }
        let l = twin()
        for skin in Skin.allCases where skin.systems == [.ds] {
            let pad = TouchPadLayout.make(layout: l, system: .ds, showsButtons: true, scale: 1, stylus: l.bottom, model: skin.padModel)
            let v = ZStack(alignment: .topLeading) {
                SkinBackground(layout: l, size: full)
                ForEach([l.top, l.bottom], id: \.minY) { r in
                    LinearGradient(colors: [Color(red: 0.2, green: 0.45, blue: 0.9), Color(red: 0.1, green: 0.2, blue: 0.5)], startPoint: .top, endPoint: .bottom)
                        .frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
                }
                ControlsOverlay(pad: pad, state: PadVisualState(), opacity: 1)
                MenuPill(darkBody: MenuPill.isDark(skin.palette), round: skin.palette).position(l.twinSpots.home)
            }
            .frame(width: full.width, height: full.height)
            .environment(\.skin, skin)
            let r = ImageRenderer(content: v); r.scale = 2
            let img = try XCTUnwrap(r.uiImage)
            try XCTUnwrap(img.pngData()).write(to: URL(fileURLWithPath: dir).appendingPathComponent("ds-ref-\(skin.rawValue).png"))
        }
        let lid = ImageRenderer(content: LidView(style: Skin.pink.lid, progress: 1).frame(width: 678, height: 466))
        lid.scale = 2
        try XCTUnwrap(lid.uiImage?.pngData()).write(to: URL(fileURLWithPath: dir).appendingPathComponent("ds-ref-lid-pink.png"))
    }
    #endif
}
