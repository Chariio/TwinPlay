// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import XCTest
@testable import TwinPlay

/// Controller events go only to the screen on top: while a game runs, the library never sees them.
final class PadScopeTests: XCTestCase {
    func testGameScopeShadowsLibraryWhilePlaying() {
        let pad = PadNavigator.shared
        pad.push("library-classic")
        pad.push("game")                       // EmulatorView appears over the Classic menu
        XCTAssertEqual(pad.top, "game")
        pad.push("game-menu")                  // in-game menu on top of the game
        XCTAssertEqual(pad.top, "game-menu")
        pad.pop("game-menu")
        XCTAssertEqual(pad.top, "game")
        pad.pop("game")                        // game closed: the library owns the controller again
        XCTAssertEqual(pad.top, "library-classic")
        pad.pop("library-classic")
    }

    func testBDuringGameplayIsDeliveredToTheGameNotTheLibrary() {
        let pad = PadNavigator.shared
        var got: [(String, PadNav)] = []
        let sub = pad.events.sink { got.append(($0.scope, $0.event)) }
        pad.push("library-classic"); pad.push("game")
        pad.inject(.b); pad.inject(.a)
        XCTAssertEqual(got.map(\.0), ["game", "game"])
        XCTAssertFalse(got.contains { $0.0 == "library-classic" })
        pad.pop("game"); pad.inject(.b)
        XCTAssertEqual(got.last?.0, "library-classic")
        pad.pop("library-classic"); sub.cancel()
    }
}
