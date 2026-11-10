// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import XCTest
import SwiftUI
@testable import TwinPlay

/// #20h The drawn lid closes like a DS on the iPhone Duo: on the inner display it covers the
/// half below the crease, hinged at the crease; on the outer display it covers everything with
/// the hinge bar on the physical hinge edge. Once the fold settles it is all or nothing.
final class LidGeometryTests: XCTestCase {
    private let inner = CGSize(width: 669, height: 951)
    private let innerLand = CGSize(width: 951, height: 669)
    private let outer = CGSize(width: 466, height: 678)
    private let outerLand = CGSize(width: 678, height: 466)

    func testInnerPortraitLidIsTheLowerHalfHingedAtTheCrease() {
        let crease = CGRect(x: 0, y: 463, width: 669, height: 24)
        let p = LidGeometry.placement(full: inner, duo: true, outer: false, orientation: .portrait, crease: crease)
        XCTAssertEqual(p.hinge, .top)
        XCTAssertEqual(p.cover, CGRect(x: 0, y: 487, width: 669, height: 951 - 487))
        // No reported crease: the middle of the display.
        let d = LidGeometry.placement(full: inner, duo: true, outer: false, orientation: .portrait)
        XCTAssertEqual(d.hinge, .top)
        XCTAssertEqual(d.cover.minY, 951 / 2, accuracy: 0.5)
        XCTAssertEqual(d.cover.maxY, 951, accuracy: 0.5)
    }

    func testInnerOtherOrientationsCoverTheNativeLowerHalf() {
        let up = LidGeometry.placement(full: inner, duo: true, outer: false, orientation: .portraitUpsideDown)
        XCTAssertEqual(up.hinge, .bottom); XCTAssertEqual(up.cover.minY, 0); XCTAssertLessThan(up.cover.maxY, 951 / 2 + 1)
        let r = LidGeometry.placement(full: innerLand, duo: true, outer: false, orientation: .landscapeRight)
        XCTAssertEqual(r.hinge, .leading); XCTAssertEqual(r.cover.maxX, 951); XCTAssertGreaterThanOrEqual(r.cover.minX, 951 / 2 - 1)
        let l = LidGeometry.placement(full: innerLand, duo: true, outer: false, orientation: .landscapeLeft)
        XCTAssertEqual(l.hinge, .trailing); XCTAssertEqual(l.cover.minX, 0); XCTAssertLessThanOrEqual(l.cover.maxX, 951 / 2 + 1)
    }

    func testOuterDisplayLidCoversAllWithTheHingeOnTop() {
        // Like a closed DS in the scene's own orientation: hinge bar on top, emblem upright, in
        // either landscape the system picks (the real Duo showed it 180 degrees off in #20h).
        for o in [UIInterfaceOrientation.landscapeRight, .landscapeLeft, .unknown] {
            XCTAssertEqual(LidGeometry.placement(full: outerLand, duo: true, outer: true, orientation: o),
                           .init(cover: CGRect(origin: .zero, size: outerLand), hinge: .top), "\(o.rawValue)")
        }
        XCTAssertEqual(LidGeometry.placement(full: outer, duo: true, outer: true, orientation: .portrait),
                       .init(cover: CGRect(origin: .zero, size: outer), hinge: .top))
    }

    func testOuterLidFollowsTheHoldBeforeTheSceneTurns() {
        // Folded, held for landscapeRight while the scene is still landscapeLeft: hinge bar on the
        // window's bottom (physically up) until the system turns the scene, then on top.
        XCTAssertEqual(LidGeometry.placement(full: outerLand, duo: true, outer: true, orientation: .landscapeLeft, held: .landscapeRight).hinge, .bottom)
        XCTAssertEqual(LidGeometry.placement(full: outerLand, duo: true, outer: true, orientation: .landscapeRight, held: .landscapeRight).hinge, .top)
        XCTAssertEqual(LidGeometry.placement(full: outerLand, duo: true, outer: true, orientation: .landscapeLeft, held: .landscapeLeft).hinge, .top)
        XCTAssertEqual(LidGeometry.upEdge(current: .portrait, held: .landscapeRight), .trailing)
        XCTAssertEqual(LidGeometry.upEdge(current: .portrait, held: .landscapeLeft), .leading)
        XCTAssertEqual(LidGeometry.upEdge(current: .landscapeRight, held: nil), .top)
        XCTAssertEqual(LidGeometry.interface(for: .landscapeLeft), .landscapeRight)
        XCTAssertNil(LidGeometry.interface(for: .faceUp))
    }

    func testOtherIPhonesKeepTheFullScreenLid() {
        let s = CGSize(width: 402, height: 874)
        XCTAssertEqual(LidGeometry.placement(full: s, duo: false, outer: false, orientation: .portrait),
                       .init(cover: CGRect(origin: .zero, size: s), hinge: .top))
    }

    func testSettledLidIsAllOrNothing() {
        XCTAssertEqual(LidGeometry.settled(0), 0)
        XCTAssertEqual(LidGeometry.settled(0.33), 0)      // the ghost: partly-open angle left it at ~1/3
        XCTAssertEqual(LidGeometry.settled(0.7), 1)
        XCTAssertEqual(LidGeometry.settled(1), 1)
    }

    func testTurnMapsTheHingeEdge() {
        XCTAssertEqual(LidGeometry.turn(for: .top), 0)
        XCTAssertEqual(LidGeometry.turn(for: .trailing), 90)
        XCTAssertEqual(LidGeometry.turn(for: .bottom), 180)
        XCTAssertEqual(LidGeometry.turn(for: .leading), -90)
    }

    @MainActor func testLidRenders() {
        let pl = LidGeometry.placement(full: inner, duo: true, outer: false, orientation: .portrait)
        for p in [0.4, 1.0] {
            let r = ImageRenderer(content: LidView(style: Skin.classicGray.lid, progress: p, placement: pl).frame(width: inner.width, height: inner.height))
            XCTAssertNotNil(r.uiImage)
        }
        let o = LidGeometry.placement(full: outer, duo: true, outer: true, orientation: .portrait)
        XCTAssertNotNil(ImageRenderer(content: LidView(style: Skin.classicGray.lid, placement: o).frame(width: outer.width, height: outer.height)).uiImage)
    }
}

/// iPad fix: the black game backdrop only goes on the app's own windows, never on the system's
/// full-screen UITextEffectsWindow above it (iPad: it covered the whole game, sound only).
final class GameWindowBackdropTests: XCTestCase {
    func testOnlyNormalLevelWindowsTurnBlack() {
        let app = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertTrue(EmulatorView.paintsBehindGame(app))
        let textEffects = UIWindow(frame: app.frame)
        textEffects.windowLevel = UIWindow.Level(rawValue: 10)
        XCTAssertFalse(EmulatorView.paintsBehindGame(textEffects))
        let alert = UIWindow(frame: app.frame)
        alert.windowLevel = .alert
        XCTAssertFalse(EmulatorView.paintsBehindGame(alert))
    }
}
