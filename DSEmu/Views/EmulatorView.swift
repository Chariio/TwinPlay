// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import SwiftUI
import UIKit
import QuartzCore
import Metal

struct EmulatorView: View {
    @ObservedObject var session: EmulatorSession
    var reviewClock = ReviewPlayClock()
    let onClose: () -> Void
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("arrangement") private var arrangementRaw = ScreenArrangement.automatic.rawValue
    @AppStorage("controlsVisibility") private var controlsVisibilityRaw = ControlsVisibility.auto.rawValue
    @AppStorage("ffMute") private var ffMute = true
    @AppStorage("renderScale") private var renderScale = QualityDefaults.renderScale
    @AppStorage("displayFilter") private var filterRaw = DisplayFilter.sharpBilinear.rawValue
    @State private var showMenu = false
    @State private var posture: FoldPosture = .flat
    @State private var hingeAngle: Double?
    @AppStorage("lidOnPause") private var lidOnPause = true
    @AppStorage("lidOnDuoClose") private var lidOnTwinClose = true
    @StateObject private var faceDown = FaceDownDetector()
    /// 0 = open, 1 = shut. Animated for pause / face-down (regular iPhone).
    @State private var lidAnim: Double = 0
    @State private var pausedByLid = false
    /// Size the game is actually laid out in (its own GeometryReader): tells the inner and outer
    /// Duo displays apart without the key-window size, which can lag a fold.
    @State private var gameSize: CGSize = .zero
    /// #20h: the hinge lid once the fold has stopped moving (all or nothing); nil while it moves.
    @State private var lidSettle: Double?
    @State private var lidSettleGen = 0
    /// How the phone is held (device orientation), for the folded Duo's lid (#20j). Read only.
    @State private var heldOrientation: UIDeviceOrientation = .unknown
    /// The scene's live interface orientation (KVO on effectiveGeometry): a 180-degree landscape
    /// flip keeps the window size, so it would not otherwise redraw the lid.
    @StateObject private var sceneOrientation = SceneOrientationObserver()
    /// Window background before the game turned it black (restored on close).
    @State private var savedWindowBackground: [ObjectIdentifier: UIColor?] = [:]
    @State private var editingSize = false
    @State private var sizeRev = 0
    @State private var draft = CustomLayout()          // layout being edited
    @State private var draftStart = CustomLayout()     // what Cancel goes back to
    @State private var editKey = ""
    @AppStorage("screenIntegerSnap") private var integerSnap = false
    @State private var pausedBeforeLid = false
    @State private var pausedBeforeModal = false
    @State private var quitting = false
    @State private var showSlots = false
    @State private var showControllerSettings = false
    @AppStorage("frameSkip") private var frameSkipRaw = FrameSkipSetting.auto.rawValue
    @AppStorage("renderer") private var renderer = "metal"
    @AppStorage("skin") private var skinRaw = Skin.classicGray.rawValue
    @AppStorage("skinGBA") private var skinGBARaw = Skin.gbaIndigo.rawValue
    @AppStorage("skinNES") private var skinNESRaw = Skin.nesFog.rawValue
    @AppStorage("skinSNES") private var skinSNESRaw = Skin.snesFog.rawValue
    @AppStorage("skinN64") private var skinN64Raw = Skin.n64Original.rawValue
    @AppStorage("skinN3DS") private var skinN3DSRaw = Skin.n3dsPearl.rawValue
    @AppStorage(TouchSettings.touchOnlyKey) private var dsTouchOnly = false
    @AppStorage(TouchSettings.scaleKey) private var touchScale = 1.0
    @AppStorage(TouchSettings.opacityKey) private var touchOpacity = 0.0
    @StateObject private var padState = PadVisualState()
    /// What the last layout pass used (window size, rejected saved screens), for the layout editor.
    @State private var probe = LayoutProbe()

    private var skin: Skin {
        let raw: String
        switch session.system.skinSystem {
        case .ds: raw = skinRaw
        case .nes: raw = skinNESRaw
        case .snes: raw = skinSNESRaw
        case .n64: raw = skinN64Raw
        case .n3ds: raw = skinN3DSRaw
        default: raw = skinGBARaw
        }
        let s = Skin.current(for: session.system, raw: raw)
        // iPhone Duo fully open: the pearl Twin shell replaces the default DS skin (any skin the
        // user picked is kept).
        if s == session.system.defaultSkin && session.system == .ds && effectivePosture == .open { return .twinPearl }
        // Closed iPhone Duo (outer display): the classic shell for the console replaces the default.
        if s == session.system.defaultSkin && onOuter { return Skin.outerDefault(for: session.system) }
        return s
    }
    /// Closed iPhone Duo: Game Boy family games keep playing on the outer display.
    private var onOuter: Bool {
        OuterDisplay.isPhone && session.isGBA && OuterDisplay.isActive(posture: effectivePosture, hingeKnown: effectiveAngle != nil,
                                               windowSize: displaySize)
    }
    /// The display the game is on: its own laid-out size, else the key window's.
    private var displaySize: CGSize { gameSize.width > 1 && gameSize.height > 1 ? gameSize : Self.keyWindowSize }
    /// The game is laid out on the Duo's outer display (the phone is folded shut).
    private var onOuterDisplay: Bool {
        OuterDisplay.isPhone && OuterDisplay.looksLikeOuter(displaySize) && (effectiveAngle != nil || effectivePosture != .flat)
    }
    /// Interface orientation of the game's window scene (read only, never changed here).
    static var interfaceOrientation: UIInterfaceOrientation {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.windows.contains(where: \.isKeyWindow) }) ?? scenes.first
        return scene?.effectiveGeometry.interfaceOrientation ?? .unknown
    }
    /// Size of the window the game is in (the display currently used: inner or outer).
    static var keyWindowSize: CGSize {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let w = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first
        return w?.bounds.size ?? .zero
    }

    @Environment(\.displayScale) private var displayScale

    private var showControls: Bool {
        #if DEBUG
        // Testing aid (simulator screenshots): -TwinPlayForceTouchControls YES
        if UserDefaults.standard.bool(forKey: "TwinPlayForceTouchControls") { return true }
        #endif
        switch ControlsVisibility(rawValue: controlsVisibilityRaw) ?? .auto {
        case .auto: return !session.controllerConnected
        case .always: return true
        case .never: return false
        }
    }

    /// DS "touch only": buttons hidden, screens laid out as if there were no controls.
    private var touchOnlyActive: Bool { dsTouchOnly && session.system == .ds }
    /// Screens leave room for the buttons only when they are drawn.
    private var layoutControls: Bool { showControls && !touchOnlyActive }

    private func padSystem() -> PadSystem {
        switch session.system {
        case .gb, .gbc: return .gameBoy
        case .gba: return .gba
        case .nes: return .nes
        case .snes: return .snes
        case .n64: return .n64
        case .n3ds: return .n3ds
        case .ds: return .ds
        }
    }

    private func controlsOpacity(_ layout: DualScreenLayout) -> Double {
        if touchOpacity > 0 { return min(max(touchOpacity, 0.2), 1) }
        return layout.isPortrait || layout.compactUnit > 0 ? skin.palette.portraitOpacity : skin.palette.landscapeOpacity
    }

    private var modalOpen: Bool { showMenu || showSlots || showControllerSettings }
    private var arrangement: ScreenArrangement { ScreenArrangement(rawValue: arrangementRaw) ?? .automatic }
    /// iPhone Duo (hinge reported, or one of its display sizes).
    private var isDuo: Bool {
        OuterDisplay.isPhone && OuterDisplay.isDuo(hingeKnown: effectiveAngle != nil, posture: effectivePosture, windowSize: displaySize)
    }
    /// The Duo keeps the DS screens stacked in every orientation (side by side only if the user
    /// picks it); "Automatic" means stacked there.
    private var dsArrangement: ScreenArrangement { isDuo && arrangement == .automatic ? .stacked : arrangement }

    var body: some View {
        // While a game is on screen it owns the controller: this scope sits above the library's,
        // so library handlers (Classic menu B = Back, A = Start...) never see in-game presses.
        // The emulated game reads the controller directly; the in-game menu pushes its own scope.
        gameBody.padScope("game") { _ in }
            .debugOuterPreview()
            .debugInnerPreview()
            .debugForceLandscape()
    }

    /// Azahar packed LCD rects in the unchanged metal area, or nil when this path is not in use.
    private func n3dsStackedLCDs(layout: DualScreenLayout, metalArea: CGRect) -> (top: CGRect, bottom: CGRect)? {
        guard session.system == .n3ds, !layout.isSingle, session.core.n3dsMetalLayer() != nil else { return nil }
        return N3DSHostStackedLayout.lcds(in: metalArea, scale: displayScale)
    }

    /// Keep the metal *display* frame equal to the layout area so drawableSize and the
    /// 60 fps present path stay unchanged. Controls are placed in the side gutters and
    /// the strip under the packed LCDs (the user can move/resize them in the editor).
    private func n3dsHandheldMetalFrame(metalArea: CGRect, full: CGSize) -> CGRect {
        return metalArea
    }

    private func mapRect(_ r: CGRect, from src: CGRect, to dst: CGRect) -> CGRect {
        let sx = dst.width / max(src.width, 1)
        let sy = dst.height / max(src.height, 1)
        return CGRect(x: dst.minX + (r.minX - src.minX) * sx,
                      y: dst.minY + (r.minY - src.minY) * sy,
                      width: r.width * sx,
                      height: r.height * sy)
    }

    /// Skin and control layout snapped to Azahar's stacked LCDs. Optionally displayed in a
    /// uniformly scaled metal frame so pads can sit beside the bottom screen.
    private func skinVisualLayout(layout: DualScreenLayout, stacked: (top: CGRect, bottom: CGRect)?,
                                  metalArea: CGRect, full: CGSize) -> (visual: DualScreenLayout, metalFrame: CGRect) {
        guard let lcds = stacked else { return (layout, metalArea) }
        let frame = n3dsHandheldMetalFrame(metalArea: metalArea, full: full)
        var visual = layout
        visual.top = mapRect(lcds.top, from: metalArea, to: frame)
        visual.bottom = mapRect(lcds.bottom, from: metalArea, to: frame)
        visual.twin = false
        visual.hinge = .zero
        visual.compactUnit = 0
        visual.isPortrait = true
        visual.isSideBySide = false
        visual.controlsArea = CGRect(origin: .zero, size: full)
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "TwinPlayLogLayout") {
            print("TWINPLAYSTACK area=\(metalArea) frame=\(frame) top=\(visual.top) bot=\(visual.bottom)")
        }
        #endif
        return (visual, frame)
    }

    /// Default 3DS display cutouts on the Duo: top LCD 15% wider than the packed
    /// hole, 400:240, centered above the hinge; bottom 320:240 shifted down in the
    /// lower box so the full image is visible. Does not change the swapchain area.
    private func n3dsDisplayCutouts(_ layout: DualScreenLayout, full: CGSize) -> (top: CGRect, bottom: CGRect) {
        let srcTop = layout.top, srcBot = layout.bottom
        let tw = srcTop.width * 1.15
        let th = tw * 240.0 / 400.0
        var tx = srcTop.midX - tw / 2
        tx = max(12, min(tx, full.width - tw - 12))
        var ty = srcTop.midY - th / 2
        let hingeLimit = srcBot.minY - 16
        if ty + th > hingeLimit { ty = hingeLimit - th }
        ty = max(12, ty)
        let top = CGRect(x: tx, y: ty, width: tw, height: th)

        let bw = srcBot.width
        let bh = bw * 240.0 / 320.0
        let bx = srcBot.midX - bw / 2
        var by = srcBot.minY + 28
        let maxBot = min(full.height - 80, srcBot.maxY + 36)
        if by + bh > maxBot { by = maxBot - bh }
        let bot = CGRect(x: bx, y: by, width: bw, height: bh)
        return (top, bot)
    }

    /// Skin + split-host cutouts: the default 3DS display placement, then any layout-editor
    /// screen placements. The packed swapchain / metalArea stay on `layout`.
    private func n3dsSkinLayout(_ layout: DualScreenLayout, custom: CustomLayout, full: CGSize) -> DualScreenLayout {
        var d = layout
        let cuts = n3dsDisplayCutouts(layout, full: full)
        d.top = cuts.top
        d.bottom = cuts.bottom
        if !custom.screens.isEmpty { d = d.applying(custom, in: full) }
        return d
    }

    /// Duo-half 3DS layout: keep the makeTwin cutouts, but route pads as a regular 3DS
    /// around the bottom screen (circle pad / D-pad left, ABXY right, L/R at the hinge).
    private func n3dsHalfVisual(layout: DualScreenLayout, split: Bool, full: CGSize) -> DualScreenLayout {
        guard split else { return layout }
        var visual = layout
        visual.twin = false
        visual.hinge = .zero
        visual.compactUnit = 0
        visual.isPortrait = true
        visual.isSideBySide = false
        visual.controlsArea = CGRect(origin: .zero, size: full)
        return visual
    }

    private var gameBody: some View {
        GeometryReader { safeGeo in
            // The reader ignores the safe area (so it covers the whole display); the insets come
            // from the window. Everything below is in full-screen coordinates.
            let ins = Self.windowInsets(fallback: safeGeo.safeAreaInsets)
            let full = safeGeo.size
            let frame = DualScreenLayout.safeFrame(full: full, insets: (ins.top, ins.leading, ins.bottom, ins.trailing))
            let shown = shownScreen
            // Host-only 3DS: leave the present path / metal area alone (ignore saved screen
            // placements that would resize the swapchain). Snap the skin to Azahar's packed
            // LCDs and let the existing control editor move/resize the pads.
            let layout = computeLayout(geo: safeGeo, full: full, frame: frame, topInset: ins.top, shown: shown,
                                       ignoreCustom: session.system == .n3ds)
            let custom = currentCustomLayout(full: full)
            let metalArea = layout.isSingle ? layout.top : layout.top.union(layout.bottom)
            let stackedLCDs = n3dsStackedLCDs(layout: layout, metalArea: metalArea)
            let skinFit = skinVisualLayout(layout: layout, stacked: stackedLCDs, metalArea: metalArea, full: full)
            // Host-only split: keep the packed swapchain and layer frame untouched.
            // Clip+transform a wrapper so the top LCD fills the top cutout; blit the
            // bottom LCD into the bottom cutout from the same presented texture.
            let n3dsSplit = session.system == .n3ds && session.core.n3dsMetalLayer() != nil && !layout.isSingle
            let visual = n3dsSplit ? n3dsHalfVisual(layout: layout, split: true, full: full) : skinFit.visual
            // Display cutouts only (skin holes + host clip/blit). metalArea is unchanged.
            let display = n3dsSplit ? n3dsSkinLayout(layout, custom: custom, full: full) : layout
            let n3dsSkinFit = n3dsSplit || stackedLCDs != nil
            ZStack(alignment: .topLeading) {
                SkinBackground(layout: display, size: full)

                if session.system == .n3ds, session.core.n3dsMetalLayer() != nil {
                    if n3dsSplit {
                        N3DSSplitHostView(session: session, area: metalArea,
                                          topCutout: display.top, botCutout: display.bottom)
                            .frame(width: full.width, height: full.height)
                            .position(x: full.width / 2, y: full.height / 2)
                    } else {
                        // Same host as 74207c7: source CAMetalLayer in `metalArea`.
                        N3DSMetalHostView(session: session, top: layout.top, bottom: layout.isSingle ? .zero : layout.bottom, area: metalArea)
                            .frame(width: metalArea.width, height: metalArea.height)
                            .position(x: metalArea.midX, y: metalArea.midY)
                    }
                } else {
                    ScreenView(session: session, screen: shown ?? 0)
                        .id("screen-\(shown ?? 0)")
                        .frame(width: layout.top.width, height: layout.top.height)
                        .position(x: layout.top.midX, y: layout.top.midY)

                    if !layout.isSingle {
                        ScreenView(session: session, screen: 1)
                            .frame(width: layout.bottom.width, height: layout.bottom.height)
                            .position(x: layout.bottom.midX, y: layout.bottom.midY)
                    }
                }

                let stylusRect: CGRect? = session.isGBA ? nil : (!visual.isSingle ? (n3dsSplit ? display.bottom : visual.bottom) : (shown == 1 ? visual.top : nil))
                let padBase = TouchPadLayout.make(layout: visual, system: padSystem(), showsButtons: layoutControls,
                                                  scale: CGFloat(touchScale), stylus: stylusRect, model: skin.padModel)
                let pad = appliedPad(padBase, custom: custom, full: full,
                                     avoid: n3dsSkinFit ? (n3dsSplit ? [display.top, display.bottom] : [visual.top, visual.bottom]) : nil)
                let padShown = showControls ? pad : TouchPadLayout(zones: [], stylus: pad.stylus, screens: pad.screens)
                // One UIKit layer takes every finger: D-pad, buttons and the DS touch screen.
                TouchInputLayer(session: session, pad: padShown, state: padState, enabled: !modalOpen && !editingSize)
                    .frame(width: full.width, height: full.height)
                    .position(x: full.width / 2, y: full.height / 2)
                    .allowsHitTesting(!modalOpen && !editingSize)
                if showControls && !padShown.zones.isEmpty {
                    ControlsOverlay(pad: padShown, state: padState, opacity: controlsOpacity(visual), held: session.holdState.shown)
                }

                let placedChrome = chromePlacements(layout: visual, pad: padShown, custom: custom, frame: frame, full: full, topInset: ins.top)
                // The classic outer shell shows only the MENU pill (no corner buttons over the screen).
                chromeButtons(placedChrome, twin: visual.twin)
                if editingSize {
                    let items = layoutEditItems(layout: n3dsSplit ? display : visual, pad: padShown, chrome: placedChrome, custom: custom, single: visual.isSingle,
                                                singleLabel: shown == 1 ? "Bottom screen" : "Top screen")
                    LayoutEditorOverlay(full: full, frame: frame, items: items, draft: $draft, integerSnap: $integerSnap,
                                        onCancel: { draft = draftStart; editingSize = false },
                                        onDone: { LayoutStore.save(draft, for: editKey, skin: skin.rawValue); sizeRev += 1; editingSize = false })
                        .zIndex(15)
                }

                // Only exists while a real fold / face-down is in progress: no faint off-screen
                // copy that a sheet or the quit transition could reveal.
                if lidProgress > 0.001 {
                    // Duo: a DS lid hinged at the crease (inner display) or at the physical hinge
                    // edge (outer display). Other iPhones: the full-screen face-down lid.
                    let duoLid = isDuo && hingeLid > 0
                    let placement = duoLid ? LidGeometry.placement(full: full, duo: true, outer: onOuterDisplay,
                                                                   orientation: sceneOrientation.current,
                                                                   crease: FoldGeometry.hinge(in: safeGeo),
                                                                   held: LidGeometry.interface(for: heldOrientation)) : nil
                    LidView(style: skin.lid, progress: lidProgress, placement: placement)
                        .frame(width: full.width, height: full.height)
                        // Re-oriented in place, never animated (no visible upside-down turn).
                        .transaction { if onOuterDisplay { $0.animation = nil } }
                        .zIndex(20)
                        .transition(.identity)
                }

                if session.isRecording {
                    // Small, unobtrusive recording indicator (stop it from the ⋯ menu).
                    Circle().fill(Color.red).frame(width: 8, height: 8)
                        .shadow(color: .black.opacity(0.4), radius: 1)
                        .position(x: frame.maxX - 14, y: frame.minY + 14)
                        .accessibilityLabel("Recording")
                        .allowsHitTesting(false)
                }
                if !editingSize { HoldButtonsBanner(session: session).position(x: frame.midX, y: frame.minY + (session.holdState.selecting ? 44 : 18)) }
                if let toast = session.toast {
                    Text(toast.loc)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .glassSurface(Capsule())
                        .position(x: frame.midX, y: frame.minY + 54)
                        .transition(.opacity)
                }
            }
            .frame(width: full.width, height: full.height)
            .onAppear { gameSize = full }
            .onChange(of: full) { gameSize = $0; sceneOrientation.start() }
        }
        .ignoresSafeArea()
        .observeHingePosture($posture, angle: $hingeAngle)
        .environment(\.skin, skin)
        .background(SkinSurround(skin: skin).ignoresSafeArea())
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .animation(.easeInOut(duration: 0.25), value: showControls)
        .animation(.easeInOut(duration: 0.25), value: dsTouchOnly)
        .animation(.easeInOut(duration: 0.3), value: posture)
        .animation(.easeInOut(duration: 0.25), value: session.screenMode)
        .animation(.easeInOut(duration: 0.2), value: session.peekHidden)
        .animation(.easeInOut(duration: 0.2), value: session.toast)
        .sheet(isPresented: $showMenu, onDismiss: modalClosed) {
            GameMenuView(session: session, onQuit: {
                quitting = true
                showMenu = false
                session.stop()
                onClose()
            })
            .modifier(GlassSheetBackground())
            .duoFullScreen(isDuo)
        }
        .sheet(isPresented: $showSlots, onDismiss: modalClosed) { SaveSlotsView(session: session).duoFullScreen(isDuo) }
        .overlay(FPSOverlay(session: session).ignoresSafeArea(.container, edges: []))
        .onChange(of: session.showMenuRequested) { requested in
            guard requested else { return }
            session.showMenuRequested = false
            if !modalOpen { openMenu() }
        }
        .onChange(of: session.showSlotsRequested) { requested in
            guard requested else { return }
            session.showSlotsRequested = false
            if !modalOpen { pausedBeforeModal = session.isPaused; session.isPaused = true; showSlots = true }
        }
        .onAppear {
            session.start()
            lidAnim = lidAnimTarget
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if lidShut { lidChanged(true) } }
            #if DEBUG
            // Testing aid (store screenshots): -TwinPlayOpenMenu <seconds> opens the game menu after a delay.
            let d = UserDefaults.standard.double(forKey: "TwinPlayOpenMenu")
            if d > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + d) { Self.debugLog("auto menu"); session.showMenuRequested = true } }
            // -TwinPlayEditLayout <seconds> opens the layout editor after a delay.
            let e = UserDefaults.standard.double(forKey: "TwinPlayEditLayout")
            if e > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + e) { session.editSizeRequested = true; startEditingLayout() } }
            // -TwinPlayFakeRecording YES shows the recording dot without recording (screenshots only).
            if UserDefaults.standard.bool(forKey: "TwinPlayFakeRecording") { session.isRecording = true }
            // -TwinPlayDumpWindows <seconds>: window / view dump + snapshot (device diagnostics).
            DebugWindowDump.schedule { "posture=\(posture) angle=\(String(describing: hingeAngle)) isDuo=\(isDuo) hingeLid=\(hingeLid) lidAnim=\(lidAnim) lidProgress=\(lidProgress) faceDown=\(faceDownNow) gameSize=\(gameSize) paused=\(session.isPaused) presenter=\(session.presenter != nil)" }
            #endif
        }
        .onDisappear { session.stop(); faceDown.stop(); restoreWindowBackground(); UIDevice.current.endGeneratingDeviceOrientationNotifications() }
        .onAppear {
            blackWindowBackground(); scheduleLidSettle()
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            sceneOrientation.start()
            heldOrientation = UIDevice.current.orientation
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            let d = UIDevice.current.orientation
            // Face up / down keeps the last hold.
            if LidGeometry.interface(for: d) != nil { var t = Transaction(); t.animation = nil; withTransaction(t) { heldOrientation = d } }
        }
        .onChange(of: hingeAngle) { _ in scheduleLidSettle() }
        .onChange(of: posture) { _ in scheduleLidSettle() }
        .onAppear { if lidOnPause { faceDown.start() } }
        .onChange(of: lidOnPause) { on in on ? faceDown.start() : faceDown.stop() }
        .onChange(of: lidShut) { shut in lidChanged(shut) }
        .onChange(of: lidAnimTarget) { t in
            withAnimation(t > 0 ? .easeIn(duration: 0.45) : .spring(response: 0.55, dampingFraction: 0.82)) { lidAnim = t }
        }
        .onAppear { reviewClock.sync(running: scenePhase == .active && !session.isPaused) }
        .onChange(of: session.isPaused) { paused in reviewClock.sync(running: scenePhase == .active && !paused) }
        .onChange(of: scenePhase) { phase in reviewClock.sync(running: phase == .active && !session.isPaused) }
        .onDisappear { reviewClock.sync(running: false) }
    }

    /// iPhone Duo: when half or fully open, lay out around the hinge (full-screen coordinates).
    static func debugLog(_ s: String) {
        #if DEBUG
        NSLog("TwinPlayLayout %@", s)
        #endif
    }

    static func windowInsets(fallback: EdgeInsets) -> EdgeInsets {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let w = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first else { return fallback }
        let i = w.safeAreaInsets
        return EdgeInsets(top: i.top, leading: i.left, bottom: i.bottom, trailing: i.right)
    }

    /// Hinge posture, with the debug override applied.
    private var effectivePosture: FoldPosture {
        #if DEBUG
        // Testing aid where the simulator cannot pose the hinge: -TwinPlayFoldPosture book|open|closed
        switch UserDefaults.standard.string(forKey: "TwinPlayFoldPosture") {
        case "book": return .book
        case "open": return .open
        case "closed": return .closed
        default: break
        }
        #endif
        return posture
    }

    /// Hinge angle in degrees (180 open flat, 0 shut), with the debug override -TwinPlayHingeAngle <deg>.
    private var effectiveAngle: Double? {
        #if DEBUG
        if let v = UserDefaults.standard.object(forKey: "TwinPlayHingeAngle") { return (v as? Double) ?? Double("\(v)") }
        // A forced posture implies its angle, so the simulator's real hinge state can't override it.
        switch UserDefaults.standard.string(forKey: "TwinPlayFoldPosture") {
        case "book": return 90
        case "open": return 180
        case "closed": return 0
        default: break
        }
        #endif
        return hingeAngle
    }

    /// How far the lid is drawn by the hinge alone: swings down over the last 60° of the fold.
    /// #20h: all or nothing except while the hinge is actually moving.
    private var hingeLid: Double {
        // Game Boy family games move to the outer display when the Duo closes: no lid.
        guard lidOnTwinClose, !quitting, !onOuter else { return 0 }
        // On the outer display the phone is shut, whatever angle / 'book' the hinge still
        // reports there: DS = closed lid (paused), GB family = none (handled above).
        if onOuterDisplay { return session.isGBA ? 0 : 1 }
        if let settled = lidSettle { return settled }
        return rawHingeLid
    }
    /// The lid straight from the hinge angle (or posture when no angle is reported).
    private var rawHingeLid: Double {
        if let a = effectiveAngle { return min(max((60 - a) / 60, 0), 1) }
        return effectivePosture == .closed ? 1 : 0
    }

    /// While the hinge moves the lid follows it; 0.6 s after the last change it snaps to fully
    /// shut or fully open, so it never stays half-drawn over the game.
    private func scheduleLidSettle() {
        lidSettle = nil
        lidSettleGen += 1
        let gen = lidSettleGen
        #if DEBUG
        // Screenshot aid: -TwinPlayLidNoSettle YES keeps a mid-fold lid (with -TwinPlayHingeAngle).
        if UserDefaults.standard.bool(forKey: "TwinPlayLidNoSettle") { return }
        #endif
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard gen == lidSettleGen else { return }
            let target = LidGeometry.settled(rawHingeLid)
            withAnimation(target > 0 ? .easeIn(duration: 0.2) : .easeOut(duration: 0.2)) { lidSettle = target }
        }
    }

    /// No white flash while the Duo moves the game between displays: black window behind it.
    /// Only the app's own windows (normal level, under the game). iPadOS keeps a full-screen
    /// system UITextEffectsWindow (Pencil / Scribble / keyboard, level 10) above the app; turning
    /// that one black covered the whole game on iPad (sound only, nothing visible).
    private func blackWindowBackground() {
        for w in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows)
        where Self.paintsBehindGame(w) {
            let id = ObjectIdentifier(w)
            if savedWindowBackground[id] == nil { savedWindowBackground[id] = .some(w.backgroundColor) }
            w.backgroundColor = .black
            #if DEBUG
            DebugWindowDump.blackened.append("\(type(of: w)) level=\(w.windowLevel.rawValue) hidden=\(w.isHidden)")
            #endif
        }
    }
    /// Windows whose background shows behind the game: the app's own (normal level). System
    /// windows layered above it (text effects, keyboard, alerts) stay transparent.
    static func paintsBehindGame(_ w: UIWindow) -> Bool { w.windowLevel == .normal }

    private func restoreWindowBackground() {
        for w in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows) {
            if let old = savedWindowBackground[ObjectIdentifier(w)] { w.backgroundColor = old }
        }
        savedWindowBackground = [:]
    }

    private var faceDownNow: Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "TwinPlayFaceDown") { return true }
        #endif
        return lidOnPause && faceDown.isFaceDown && !showMenu && !showSlots && !quitting
    }

    /// Regular-iPhone lid: closes ONLY when the phone is face-down (the Duo hinge drives
    /// `hingeLid`). Never for the in-game menu, a menu pause or Quit: the glass menu shows
    /// the frozen game frame behind it.
    private var lidAnimTarget: Double { faceDownNow && !quitting ? 1 : 0 }
    private var lidProgress: Double { quitting ? 0 : max(hingeLid, lidAnim) }
    /// Conditions that pause the game: hinge fully shut or face-down.
    private var lidShut: Bool { hingeLid >= 1 || faceDownNow }

    private func lidChanged(_ shut: Bool) {
        if shut {
            guard !pausedByLid else { return }
            pausedBeforeLid = session.isPaused
            session.fastForwardOn = false
            session.isPaused = true
            session.flushSave()
            pausedByLid = true
        } else if pausedByLid {
            pausedByLid = false
            if !pausedBeforeLid && !modalOpen { session.isPaused = false }
        }
    }

    private var shownScreen: Int? {
        if session.isGBA || !Store.allows(.screenLayouts) || duoShowsBoth { return nil }
        return session.screenMode.shownScreen(peek: session.peekHidden)
    }
    /// An unfolded iPhone Duo always shows both DS screens: the two halves are the DS's two
    /// screens. A per-game "Top/Bottom screen only" mode (easy to set by accident with the menu
    /// row or a controller shortcut, then remembered for that game) left NSMB on one screen with
    /// the Duo open. Single-screen modes still apply on regular iPhones and iPad. Uses isDuo (not
    /// only the hinge posture) so a hinge reading that is late at launch (posture .flat) counts.
    private var duoShowsBoth: Bool {
        ScreenMode.duoShowsBoth(isGBA: session.isGBA, isDuo: isDuo,
                                onOuter: OuterDisplay.isActive(posture: effectivePosture, hingeKnown: effectiveAngle != nil, windowSize: displaySize))
    }

    /// Screen sizes are saved per layout: posture, orientation, screen mode and arrangement.
    private func sizeKey(full: CGSize) -> String {
        let p: String
        switch effectivePosture { case .book: p = "book"; case .open: p = "open"; case .closed where session.isGBA: p = "outer"; default: p = "flat" }
        let mode: String
        switch session.system {
        case .gb, .gbc: mode = "gb"
        case .gba: mode = "gba"
        case .nes: mode = "nes"
        case .snes: mode = "snes"
        case .n64: mode = "n64"
        case .n3ds: mode = shownScreen.map { $0 == 0 ? "top" : "bottom" } ?? "both"
        case .ds: mode = shownScreen.map { $0 == 0 ? "top" : "bottom" } ?? "both"
        }
        return "\(p).\(full.height >= full.width ? "portrait" : "landscape").\(mode).\(arrangement.rawValue)"
    }

    /// Apply saved (or draft) control placements. While the editor is open, apply the draft
    /// exactly so move/resize isn't snapped back. When playing a 3DS game, skip a saved
    /// placement only if it would sit on an LCD (legacy Duo layouts).
    private func appliedPad(_ base: TouchPadLayout, custom: CustomLayout, full: CGSize, avoid: [CGRect]?) -> TouchPadLayout {
        if let screens = avoid, !editingSize {
            return base.applying(custom, in: full, avoiding: screens)
        }
        return base.applying(custom, in: full)
    }

    /// The user's layout for this orientation / console (the draft while the editor is open).
    private func currentCustomLayout(full: CGSize) -> CustomLayout {
        if editingSize { return draft }
        _ = sizeRev
        return LayoutStore.load(LayoutStore.key(layoutKey: sizeKey(full: full)), skin: skin.rawValue)
    }

    /// Default layout for the current state, with the user's screen placement on top.
    private func computeLayout(geo: GeometryProxy, full: CGSize, frame: CGRect, topInset: CGFloat, shown: Int?, ignoreCustom: Bool = false) -> DualScreenLayout {
        // The corner buttons live in the top inset (beside the Dynamic Island); only displays
        // without enough inset reserve a strip, so the screens get the whole width and height.
        let reserve = frame.height >= frame.width ? DualScreenLayout.topReserve(forInset: topInset) : 0
        let base0: DualScreenLayout
        if session.isGBA {
            let margin: CGFloat = skin.shellStyle == .brick || skin.shellStyle == .color ? 40 : 12
            base0 = DualScreenLayout.makeSingle(size: frame.size, showsControls: layoutControls, aspect: session.singleAspect,
                                                portraitMargin: margin, topReserve: reserve)
        } else if shown != nil {
            base0 = DualScreenLayout.makeSingle(size: frame.size, showsControls: layoutControls, aspect: 4.0 / 3.0, topReserve: reserve)
        } else {
            base0 = DualScreenLayout.make(size: frame.size, arrangement: dsArrangement, showsControls: layoutControls, topReserve: reserve)
        }
        let wide = session.widescreen && !session.isGBA && shown == nil
        let base1 = wide ? base0.widenedTop(in: frame.size) : base0
        let normal = base1.offsetBy(dx: frame.minX, dy: frame.minY)
        let outer = OuterDisplay.usesClassicShell(system: session.system, outer: onOuter, size: full)
            ? DualScreenLayout.makeOuter(size: full, aspect: session.singleAspect, gba: !session.isGameBoy) : nil
        // #14 iPad (and other large windows): the DS reference layout when the proportions fit.
        let reference = !session.isGBA && shown == nil && !wide && layoutControls && skin.shellStyle == .twin
            ? DualScreenLayout.makeReference(frame: frame) : nil
        let raw = outer ?? foldedLayout(geo: geo, full: full, single: shown != nil) ?? reference ?? normal
        // Duo: a saved placement that would swap or stack the two screens on each other (saved
        // for another posture / orientation) is ignored.
        if ignoreCustom {
            probe.full = full
            probe.rejectedScreens = false
            let px = displayScale
            return integerSnap
                ? raw.resized(top: 1, bottom: 1, snap: true, displayScale: px, bounds: CGRect(origin: .zero, size: full)).pixelAligned(scale: px)
                : raw.pixelAligned(scale: px)
        }
        let checked = raw.applyingChecked(currentCustomLayout(full: full), in: full, foldable: isDuo && outer == nil)
        let placed = checked.layout
        probe.full = full
        probe.rejectedScreens = checked.rejectedScreens
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "TwinPlayLogLayout") {
            print("TWINPLAYLAYOUT ins=\(Self.windowInsets(fallback: geo.safeAreaInsets)) full=\(full) hinge=\(FoldGeometry.hinge(in: geo).map { "\($0)" } ?? "nil") raw.top=\(raw.top) raw.bottom=\(raw.bottom) placed.top=\(placed.top) area=\(raw.controlsArea) twin=\(raw.twin) unit=\(raw.compactUnit)")
        }
        #endif
        let px = displayScale
        guard integerSnap else { return placed.pixelAligned(scale: px) }
        return placed.resized(top: 1, bottom: 1, snap: true, displayScale: px, bounds: CGRect(origin: .zero, size: full))
            .pixelAligned(scale: px)
    }

    typealias ChromePlacement = (control: LayoutControl, size: CGSize, spot: (CGPoint, CGFloat))

    private var swapShown: Bool { session.screenMode != .both && !session.isGBA && !duoShowsBoth }
    private var hasTouchGroup: Bool { swapShown || (!session.isGBA && showControls) }

    /// Where the touch / fast-forward / menu buttons go: the user's placement, else the default
    /// spot (off the game screens). Always inside the display (the menu inside the safe area).
    private func chromePlacements(layout: DualScreenLayout, pad: TouchPadLayout, custom: CustomLayout,
                                  frame: CGRect, full: CGSize, topInset: CGFloat) -> [ChromePlacement] {
        let portraitMode = frame.height >= frame.width
        let spots = layout.chromeSpots(in: frame, topInset: portraitMode ? topInset : 0, avoid: pad.zones.map(\.hit))
        let scr = layout.isSingle ? layout.top : layout.top.union(layout.bottom)
        let narrow = frame.maxX - scr.maxX < 104
        let menuDefault: CGPoint = {
            // Physical 3DS: Home/Menu sits with Start/Select, centered under the bottom LCD.
            if session.system == .n3ds && !layout.twin && layout.bottom.maxY > 0 {
                return CGPoint(x: layout.bottom.midX, y: min(layout.bottom.maxY + 24, full.height - 50))
            }
            return layout.outer ? layout.outerSpots.menu : layout.twin ? layout.twinSpots.home : spots.menuBesideRight
                ? CGPoint(x: spots.right.x - (narrow ? 0 : 54), y: spots.right.y + (narrow ? 50 : 0)) : spots.menu
        }()
        let touchW: CGFloat = swapShown ? (!session.isGBA && showControls ? 98 : 48) : 44
        let defaults: [(LayoutControl, CGPoint, CGSize)] = [
            (.touch, spots.left, CGSize(width: touchW, height: 44)),
            (.ff, spots.right, CGSize(width: 48, height: 44)),
            (.menu, menuDefault, MenuPill.hitSize),
        ]
        // The classic outer shell: only the MENU pill.
        return defaults.filter { ($0.0 != .touch || hasTouchGroup) && (!layout.outer || $0.0 == .menu) }.map { c, d, size in
            guard let p = custom.control(c) else { return (c, size, (d, 1)) }
            let k = CGFloat(min(max(p.size, c.scaleRange.lowerBound), c.scaleRange.upperBound))
            let bound = c == .menu ? frame.insetBy(dx: 4, dy: 4) : CGRect(origin: .zero, size: full)
            let w = size.width * k, h = size.height * k
            let x = min(max(CGFloat(p.cx) * full.width, bound.minX + w / 2), bound.maxX - w / 2)
            let y = min(max(CGFloat(p.cy) * full.height, bound.minY + h / 2), bound.maxY - h / 2)
            return (c, size, (CGPoint(x: x, y: y), k))
        }
    }

    /// Drawn last, above everything, so game input views never steal their taps.
    @ViewBuilder private func chromeButtons(_ placed: [ChromePlacement], twin: Bool = false) -> some View {
        ForEach(placed, id: \.control) { item in
            chromeButton(item.control, twin: twin)
                .fixedSize()
                .scaleEffect(item.spot.1)
                .position(item.spot.0)
                .zIndex(10)
                .allowsHitTesting(!editingSize)
        }
    }

    @ViewBuilder private func chromeButton(_ c: LayoutControl, twin: Bool = false) -> some View {
        switch c {
        case .touch:
            HStack(spacing: 6) {
                if swapShown { swapButton }
                touchOnlyButton
            }
        case .ff: fastForwardButton
        default: menuButton(twin: twin)
        }
    }

    private var swapButton: some View {
        Button { ButtonHaptics.tap(); session.peekHidden.toggle() } label: {
            Image(systemName: "rectangle.2.swap")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(session.peekHidden ? Color.accentColor : skin.palette.menuTint)
                .frame(width: 48, height: 44).contentShape(Rectangle())
                .glassSurface(Capsule(), interactive: true)
        }
        .accessibilityLabel((session.peekHidden ? "Back to the chosen screen" : "Show the hidden screen").loc)
    }

    /// What the layout editor can move right now: the screens, the control groups that are drawn,
    /// and the in-game buttons, each with its current rectangle.
    private func layoutEditItems(layout: DualScreenLayout, pad: TouchPadLayout, chrome: [ChromePlacement],
                                 custom: CustomLayout, single: Bool, singleLabel: String) -> [LayoutEditItem] {
        var out: [LayoutEditItem] = []
        // 3DS screens in the editor move only the host display cutouts (skin holes +
        // clip/blit dests). The packed swapchain / metalArea stay fixed so the 60 fps
        // path is unchanged. Other consoles already edit their screens the same way.
        out.append(LayoutEditItem(kind: .screen("top"), rect: layout.top, label: single ? String(localized: String.LocalizationValue(singleLabel)) : String(localized: "Top screen")))
        if !single { out.append(LayoutEditItem(kind: .screen("bottom"), rect: layout.bottom, label: String(localized: "Bottom screen"))) }
        for (c, rect) in pad.groupRects.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            out.append(LayoutEditItem(kind: .control(c), rect: rect, scale: custom.control(c)?.size ?? 1, label: c.label))
        }
        for (c, size, pk) in chrome {
            out.append(LayoutEditItem(kind: .control(c), rect: CGRect(x: pk.0.x - size.width * pk.1 / 2, y: pk.0.y - size.height * pk.1 / 2,
                                                                   width: size.width * pk.1, height: size.height * pk.1),
                                      scale: Double(pk.1), label: c.label))
        }
        return out
    }

    /// Opens the layout editor for the current orientation and console.
    private func startEditingLayout() {
        // The key must come from the same window size the layout is drawn (and loaded) with.
        // `UIScreen.main.bounds` is not that on the Duo (two displays, and it can lag a rotation),
        // so a layout edited in one posture / orientation was saved under another one's key and
        // then shown there (e.g. the screens swapped and shrunk whenever the Duo went flat).
        let size = probe.full.width > 1 ? probe.full : UIScreen.main.bounds.size
        editKey = LayoutStore.key(layoutKey: sizeKey(full: size))
        draft = LayoutStore.load(editKey, skin: skin.rawValue)
        // Saved screens that the layout ignores start from the default again in the editor.
        if probe.rejectedScreens { draft.screens = [:] }
        draftStart = draft
        editingSize = true
    }

    private func foldedLayout(geo: GeometryProxy, full: CGSize, single: Bool = false) -> DualScreenLayout? {
        let posture = effectivePosture
        guard posture == .book || posture == .open else { return nil }
        // Landscape: the hinge runs top to bottom. The DS screens stay stacked in the regular
        // landscape layout (controls at the sides) instead of being split across the fold.
        if !session.isGBA && full.width > full.height { return nil }
        let ins = Self.windowInsets(fallback: geo.safeAreaInsets)
        let hx = max(ins.leading, ins.trailing)
        let safe = CGRect(x: hx, y: ins.top, width: full.width - hx * 2, height: full.height - ins.top - ins.bottom)
        let hinge = FoldGeometry.hinge(in: geo) ?? FoldGeometry.defaultHinge(full: full)
        if single && !session.isGBA {
            // One DS screen: same placement as the GBA screen, at 4:3.
            return DualScreenLayout.makeFolded(safe: safe, hinge: hinge, posture: posture, isGBA: true,
                                               showsControls: layoutControls, gbaAspect: 4.0 / 3.0)
        }
        return DualScreenLayout.makeFolded(safe: safe, hinge: hinge, posture: posture, isGBA: session.isGBA,
                                           showsControls: layoutControls, gbaAspect: session.singleAspect,
                                           twin: skin.shellStyle == .twin && posture == .open)
    }

    /// Opens the game menu as a sheet with the game paused (resumed on close unless the user paused it).
    /// The classic dark MENU pill on every skin.
    private func menuButton(twin: Bool) -> some View {
        Button { ButtonHaptics.tap(); openMenu() } label: { MenuPill(darkBody: MenuPill.isDark(skin.palette), round: twin ? skin.palette : nil) }
            .buttonStyle(.plain)
            .accessibilityLabel("Game menu")
    }

    private func openMenu() {
        pausedBeforeModal = session.isPaused
        session.fastForwardOn = false
        session.isPaused = true
        showMenu = true
    }

    private func modalClosed() {
        guard !showMenu && !showSlots && !showControllerSettings else { return }
        if session.editSizeRequested { session.editSizeRequested = false; startEditingLayout() }
        if !pausedBeforeModal && !quitting { session.isPaused = false }
    }

    /// DS: hide the buttons for stylus-only games (the bottom screen is left unobstructed).
    @ViewBuilder private var touchOnlyButton: some View {
        if !session.isGBA && showControls {
            Button { ButtonHaptics.tap(); dsTouchOnly.toggle() } label: {
                Image(systemName: dsTouchOnly ? "hand.point.up.left.fill" : "hand.point.up.left")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(dsTouchOnly ? Color.accentColor : skin.palette.menuTint)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
                    .glassSurface(Capsule(), interactive: true)
            }
            .accessibilityLabel((dsTouchOnly ? "Show the buttons" : "Touch only: hide the buttons").loc)
        }
    }

    private var fastForwardButton: some View {
        Button { ButtonHaptics.tap(); session.fastForwardOn.toggle() } label: {
            Text(session.fastForwardOn ? (session.fastForwardSpeed == 0 ? "»∞" : "»x\(session.fastForwardSpeed)") : "»")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .frame(minWidth: 44, minHeight: 44)
                .foregroundStyle(session.fastForwardOn ? Color.white : skin.palette.menuTint)
                .glassSurface(Capsule(), interactive: true, tint: session.fastForwardOn ? Color.accentColor : nil)
        }
        .accessibilityLabel((session.fastForwardOn ? "Stop fast-forward" : "Fast-forward").loc)
    }
}

/// Whether the touch controls are drawn. "Automatic" hides them while a controller is connected.
enum ControlsVisibility: String, CaseIterable, Identifiable {
    case auto, always, never
    var id: String { rawValue }
    var label: String { englishLabel.loc }
    /// English source text (the String Catalog key).
    var englishLabel: String {
        switch self {
        case .auto: return "Automatic (hide with controller)"
        case .always: return "Always show"
        case .never: return "Always hide"
        }
    }
}

/// Reference box written during the layout pass (no view update), read by the layout editor.
final class LayoutProbe {
    var full: CGSize = .zero
    var rejectedScreens = false
}

/// #12 Hold Buttons chrome: the picker banner while choosing, then a small chip naming what is
/// held (tap it to let go of everything).
struct HoldButtonsBanner: View {
    @ObservedObject var session: EmulatorSession

    var body: some View {
        let h = session.holdState
        if h.selecting {
            VStack(spacing: 6) {
                Text("Hold Buttons").font(.subheadline.weight(.semibold))
                Text(h.pending.isEmpty ? "Tap the buttons to keep pressed".loc : h.pending.names)
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                HStack(spacing: 10) {
                    Button("Cancel") { ButtonHaptics.tap(); session.cancelHoldSelection() }
                        .buttonStyle(.bordered)
                    Button("Hold") { ButtonHaptics.tap(); session.confirmHoldSelection() }
                        .buttonStyle(.borderedProminent)
                }
                .font(.footnote.weight(.semibold))
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .glassSurface(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .frame(maxWidth: 300)
        } else if !h.held.isEmpty {
            Button { ButtonHaptics.tap(); session.releaseHeldButtons() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "pin.fill")
                    Text(h.held.names).lineLimit(1)
                    Image(systemName: "xmark")
                }
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .glassSurface(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Release held buttons: \(h.held.names)"))
        }
    }
}

extension OuterDisplay {
    /// The Duo checks only apply on iPhones: an iPad Stage Manager window can happen to have the
    /// Duo's inner or outer display size.
    static var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }
}

/// Publishes the game window scene's interface orientation as soon as UIKit changes it (#20j).
/// Read only: it never requests or limits an orientation.
final class SceneOrientationObserver: ObservableObject {
    @Published private(set) var current: UIInterfaceOrientation = .unknown
    private var token: NSKeyValueObservation?
    private weak var scene: UIWindowScene?

    func start() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let s = scenes.first(where: { $0.windows.contains(where: \.isKeyWindow) }) ?? scenes.first else { return }
        set(s.effectiveGeometry.interfaceOrientation)
        guard s !== scene else { return }
        scene = s
        token = s.observe(\.effectiveGeometry, options: [.new]) { [weak self] sc, _ in
            let o = sc.effectiveGeometry.interfaceOrientation
            if Thread.isMainThread { self?.set(o) } else { DispatchQueue.main.async { self?.set(o) } }
        }
    }

    private func set(_ o: UIInterfaceOrientation) {
        guard o != current else { return }
        var t = Transaction(); t.animation = nil
        withTransaction(t) { current = o }
    }
}


fileprivate func tpAspectFit(_ aspect: CGFloat, in r: CGRect) -> CGRect {
    guard r.width > 8, r.height > 8, aspect > 0 else { return r }
    var w = r.width, h = w / aspect
    if h > r.height { h = r.height; w = h * aspect }
    return CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
}

/// Scale `aspect` (width/height) to completely fill `r`, cropping overflow.
fileprivate func tpAspectFill(_ aspect: CGFloat, in r: CGRect) -> CGRect {
    guard r.width > 8, r.height > 8, aspect > 0 else { return r }
    var w = r.width, h = w / aspect
    if h < r.height { h = r.height; w = h * aspect }
    return CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
}

/// Map a rect in top-left UIKit space to CALayer contentsRect (unit space, origin lower left).
/// Used only on the destination blit layer, never on the source CAMetalLayer.
fileprivate func tpUnitRect(_ r: CGRect, in bounds: CGRect) -> CGRect {
    guard bounds.width > 0, bounds.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
    let x = (r.minX - bounds.minX) / bounds.width
    let w = r.width / bounds.width
    let h = r.height / bounds.height
    let yTop = (r.minY - bounds.minY) / bounds.height
    return CGRect(x: x, y: 1 - yTop - h, width: w, height: h)
}

/// Bottom LCD crop in the presented drawable, from Azahar's PortraitTopFullWidth
/// 400x540 pack (top 240 + bottom 300, gap 0, stack shifted so top is at y = 0).
/// scale_factor 0.8 already scales the native 320x240 bottom LCD to a full-width
/// 400x300 slot — do not inset 40/400, that clipped ~10% off each side (visible
/// as a missing first letter on left-aligned menu text). Independent of the
/// editor/top cutout size. contentsRect is top-left unit space.
fileprivate func tpPackedBottomContentsRect(drawable: CGSize) -> CGRect {
    let fbW = max(Int(drawable.width.rounded()), 1)
    let fbH = max(Int(drawable.height.rounded()), 1)
    let emuW: Float = 400
    let emuH: Float = 540
    let fit = min(Float(fbW) / emuW, Float(fbH) / emuH)
    let totW = Int(emuW * fit)
    let totH = Int(emuH * fit)
    let left = (fbW - totW) / 2
    let top0 = (fbH - totH) / 2
    let amount = Float(totH) / emuH
    let largeLeft = left
    let largeRight = Int(400 * amount + Float(left))
    let largeBottom = Int(240 * amount + Float(top0))
    let smallH = Int(300 * amount + Float(top0)) - top0
    let largeH = largeBottom - top0
    // After Azahar's shiftY, the top LCD is at y = 0; the bottom is the full
    // 400x300 slot immediately below it (already 4:3, same width as the top).
    let x = CGFloat(largeLeft)
    let y = CGFloat(largeH)
    let w = CGFloat(max(1, largeRight - largeLeft))
    let h = CGFloat(max(1, smallH))
    return CGRect(x: x / CGFloat(fbW), y: y / CGFloat(fbH),
                  width: w / CGFloat(fbW), height: h / CGFloat(fbH))
}

/// Folium-style host split: one working CAMetalLayer/swapchain (size still `area`).
/// The source layer frame and contentsRect are never changed; framebufferOnly stays
/// at MoltenVK's default. A container with masksToBounds + a CALayer mask clips the
/// packed stack so only the top LCD (aspect-filled, 400:240) is visible in the top
/// cutout. The bottom LCD is sampled onto a separate blit layer in the lower box.
/// Cutout rects are converted from window space with convert(_:from: nil).
struct N3DSSplitHostView: UIViewRepresentable {
    let session: EmulatorSession
    let area: CGRect
    let topCutout: CGRect
    let botCutout: CGRect

    func makeUIView(context: Context) -> N3DSSplitHostUIView {
        let v = N3DSSplitHostUIView()
        v.session = session
        v.area = area
        v.topCutout = topCutout
        v.botCutout = botCutout
        v.attachMetal()
        return v
    }

    func updateUIView(_ uiView: N3DSSplitHostUIView, context: Context) {
        uiView.session = session
        uiView.area = area
        uiView.topCutout = topCutout
        uiView.botCutout = botCutout
        uiView.setNeedsLayout()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: N3DSSplitHostUIView, context: Context) -> CGSize {
        if let w = proposal.width, let h = proposal.height, w > 8 && h > 8 { return CGSize(width: w, height: h) }
        return uiView.bounds.size
    }
}

final class N3DSSplitHostUIView: UIView {
    weak var session: EmulatorSession?
    var area: CGRect = .zero
    /// Cutouts in SwiftUI/layout space (full-screen, same as window when this view fills it).
    var topCutout: CGRect = .zero
    var botCutout: CGRect = .zero

    private var source: N3DSMetalHostUIView?
    private let wrapper = UIView()
    private let topClip = UIView()
    private let clipMask = CAShapeLayer()
    private let botView = UIView()
    private let botContents = CALayer()
    private var link: CADisplayLink?
    private var shotTicks = 0
    #if DEBUG
    private var framesSeen = 0
    private var wroteVerifyShot = false
    private var loggedContents = false
    private var loggedTouch = false
    #endif

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false

        topClip.clipsToBounds = true
        topClip.layer.masksToBounds = true
        topClip.isUserInteractionEnabled = false
        topClip.isOpaque = true
        topClip.backgroundColor = .black
        clipMask.fillColor = UIColor.white.cgColor
        topClip.layer.mask = clipMask

        wrapper.isUserInteractionEnabled = false
        wrapper.backgroundColor = .clear
        wrapper.isOpaque = false
        topClip.addSubview(wrapper)

        botView.isUserInteractionEnabled = false
        botView.isOpaque = true
        botView.backgroundColor = .black
        botView.clipsToBounds = true
        botView.layer.masksToBounds = true
        botContents.contentsGravity = .resize
        botContents.masksToBounds = true
        botView.layer.addSublayer(botContents)

        addSubview(topClip)
        addSubview(botView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    func attachMetal() {
        guard source == nil, let session else { return }
        let raw = session.core.n3dsMetalLayer()
        let layer = raw.map { Unmanaged<CAMetalLayer>.fromOpaque($0).takeUnretainedValue() }
        // Do not touch framebufferOnly or contentsRect on the source layer.
        let host = N3DSMetalHostUIView(metalLayer: layer, session: session)
        host.area = area
        wrapper.addSubview(host)
        source = host
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            if link == nil {
                let l = CADisplayLink(target: self, selector: #selector(tick))
                l.add(to: .main, forMode: .common)
                link = l
            }
            setNeedsLayout()
        } else {
            link?.invalidate()
            link = nil
        }
    }

    /// Layout-space cutout (window coords) → this view's local space.
    private func localCutout(_ r: CGRect) -> CGRect {
        if window != nil { return convert(r, from: nil) }
        return r
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let source, area.width >= 8, area.height >= 8,
              topCutout.width > 8, topCutout.height > 8,
              botCutout.width > 8, botCutout.height > 8 else { return }
        let scale = window?.screen.scale ?? UIScreen.main.scale
        let packed = CGRect(origin: .zero, size: area.size)
        guard let lcds = N3DSHostStackedLayout.lcds(in: packed, scale: scale) else { return }

        source.area = area
        wrapper.transform = .identity
        source.frame = CGRect(origin: .zero, size: area.size)
        source.setNeedsLayout()
        source.layoutIfNeeded()

        let topLocalCutout = localCutout(topCutout)
        let botLocalCutout = localCutout(botCutout)

        topClip.frame = topLocalCutout
        clipMask.frame = topClip.bounds
        clipMask.path = UIBezierPath(rect: topClip.bounds).cgPath
        topClip.layer.masksToBounds = true

        // Aspect-fill 400:240 into the top cutout so the LCD covers the hole
        // (no letterbox). After this scale the packed bottom LCD starts at the
        // cutout's bottom edge and is hidden by the container mask.
        let fillTop = tpAspectFill(400.0 / 240.0, in: topClip.bounds)
        let topLCD = lcds.top
        let s = fillTop.height / max(topLCD.height, 1)
        wrapper.layer.anchorPoint = CGPoint(x: 0, y: 0)
        wrapper.bounds = CGRect(origin: .zero, size: area.size)
        wrapper.layer.position = CGPoint(x: fillTop.minX - topLCD.minX * s,
                                         y: fillTop.minY - topLCD.minY * s)
        wrapper.transform = CGAffineTransform(scaleX: s, y: s)

        botView.frame = tpAspectFit(320.0 / 240.0, in: botLocalCutout)
        // Crop from the actual drawable and the 400x540 packed layout only —
        // never from the editor size or the top-cutout / aspect-fill height.
        let fb = source.metalLayerForSplit?.drawableSize ?? CGSize(width: area.width, height: area.height)
        let botUnit = tpPackedBottomContentsRect(drawable: fb)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        botContents.frame = botView.bounds
        botContents.contentsRect = botUnit
        CATransaction.commit()

        #if DEBUG
        let winRect = convert(bounds, to: nil)
        NSLog("TwinPlay 3DS split-host fb-area=%.0fx%.0f scale=%.1f s=%.3f bounds=%.0f,%.0f %.0fx%.0f win=%.0f,%.0f %.0fx%.0f rawTop=%.0f,%.0f %.0fx%.0f locTop=%.0f,%.0f %.0fx%.0f fillTop=%.0f,%.0f %.0fx%.0f rawBot=%.0f,%.0f %.0fx%.0f locBot=%.0f,%.0f %.0fx%.0f botFit=%.0f,%.0f %.0fx%.0f lcdTop=%.0f,%.0f %.0fx%.0f lcdBot=%.0f,%.0f %.0fx%.0f",
              area.width, area.height, scale, s,
              bounds.minX, bounds.minY, bounds.width, bounds.height,
              winRect.minX, winRect.minY, winRect.width, winRect.height,
              topCutout.minX, topCutout.minY, topCutout.width, topCutout.height,
              topLocalCutout.minX, topLocalCutout.minY, topLocalCutout.width, topLocalCutout.height,
              fillTop.minX, fillTop.minY, fillTop.width, fillTop.height,
              botCutout.minX, botCutout.minY, botCutout.width, botCutout.height,
              botLocalCutout.minX, botLocalCutout.minY, botLocalCutout.width, botLocalCutout.height,
              botView.frame.minX, botView.frame.minY, botView.frame.width, botView.frame.height,
              topLCD.minX, topLCD.minY, topLCD.width, topLCD.height,
              lcds.bottom.minX, lcds.bottom.minY, lcds.bottom.width, lcds.bottom.height)
        NSLog("TwinPlay 3DS split-blit fb=%.0fx%.0f unit=%.3f,%.3f %.3fx%.3f dest=%.0f,%.0f %.0fx%.0f",
              fb.width, fb.height, botUnit.minX, botUnit.minY, botUnit.width, botUnit.height,
              botView.frame.minX, botView.frame.minY, botView.frame.width, botView.frame.height)
        #endif
    }

    @objc private func tick() {
        guard let metal = source?.metalLayerForSplit else { return }
        // Sample without changing the source layer. contents may be nil while
        // framebufferOnly stays at the default; we just skip those frames.
        if let contents = metal.contents ?? metal.presentation()?.contents {
            botContents.contents = contents
            shotTicks += 1
            // Copy a still often enough for the library banner / save-state
            // thumb, but not every frame (IOSurface → CGImage is not free).
            if shotTicks == 1 || shotTicks % 10 == 0, let session,
               let img = PlaySnapshotQuality.image(fromLayerContents: contents) {
                session.noteN3DSPackedScreenshot(img)
            }
            #if DEBUG
            if !loggedContents {
                loggedContents = true
                NSLog("TwinPlay 3DS split-blit contents=ok")
            }
            #endif
        } else {
            #if DEBUG
            if !loggedContents {
                loggedContents = true
                NSLog("TwinPlay 3DS split-blit contents=nil")
            }
            #endif
        }
        #if DEBUG
        framesSeen += 1
        if !wroteVerifyShot, framesSeen >= 90 {
            writeVerifyShot()
        }
        if !loggedTouch, framesSeen == 120, let session {
            // Software stylus tap at the centre of the bottom LCD (core space is 256x192,
            // mapped to 320x240 inside N3DSCore). Logs whether the session accepted it.
            session.touch(down: true, x: 128, y: 96)
            NSLog("TwinPlay 3DS split-touch down=1 x=128 y=96")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                session.touch(down: false, x: 128, y: 96)
                NSLog("TwinPlay 3DS split-touch up=1")
                self?.loggedTouch = true
            }
        }
        #endif
    }

    #if DEBUG
    private func writeVerifyShot() {
        wroteVerifyShot = true
        guard let win = window else { return }
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = win.screen.scale
        let img = UIGraphicsImageRenderer(bounds: win.bounds, format: fmt).image { _ in
            win.drawHierarchy(in: win.bounds, afterScreenUpdates: false)
        }
        guard let data = img.pngData(),
              let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = dir.appendingPathComponent("TWINPLAY-split-verify.png")
        do {
            try data.write(to: url)
            NSLog("TwinPlay 3DS split-verify wrote %@ bytes=%d", url.path, data.count)
        } catch {
            NSLog("TwinPlay 3DS split-verify write failed: %@", error.localizedDescription)
        }
    }
    #endif
}

/// Hosts Azahar's MoltenVK CAMetalLayer in the 3DS screen area. Simple visible
/// layer filling `area` — the known-good 60 fps present path. No compositor,
/// mask, or CustomLayout (those dropped the present path to ~2 fps / black).
struct N3DSMetalHostView: UIViewRepresentable {
    let session: EmulatorSession
    let top: CGRect
    let bottom: CGRect
    let area: CGRect

    func makeUIView(context: Context) -> N3DSMetalHostUIView {
        let raw = session.core.n3dsMetalLayer()
        let layer = raw.map { Unmanaged<CAMetalLayer>.fromOpaque($0).takeUnretainedValue() }
        let v = N3DSMetalHostUIView(metalLayer: layer, session: session)
        v.area = area
        return v
    }

    func updateUIView(_ uiView: N3DSMetalHostUIView, context: Context) {
        uiView.session = session
        uiView.area = area
        uiView.invalidateIntrinsicContentSize()
        uiView.setNeedsLayout()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: N3DSMetalHostUIView, context: Context) -> CGSize {
        if area.width > 8 && area.height > 8 { return area.size }
        if let w = proposal.width, let h = proposal.height, w > 8 && h > 8 { return CGSize(width: w, height: h) }
        return uiView.bounds.size
    }
}

final class N3DSMetalHostUIView: UIView {
    private let metalLayer: CAMetalLayer?
    /// Read-only access for the split host's bottom-LCD blit. Do not change
    /// this layer's frame or contentsRect from outside layoutSubviews.
    var metalLayerForSplit: CAMetalLayer? { metalLayer }
    weak var session: EmulatorSession?
    var area: CGRect = .zero
    private var lastFbW = 0
    private var lastFbH = 0

    override var intrinsicContentSize: CGSize {
        area.width > 8 && area.height > 8 ? area.size : super.intrinsicContentSize
    }

    init(metalLayer: CAMetalLayer?, session: EmulatorSession) {
        self.metalLayer = metalLayer
        self.session = session
        super.init(frame: .zero)
        isOpaque = true
        backgroundColor = .black
        isUserInteractionEnabled = false
        if let metalLayer {
            metalLayer.removeFromSuperlayer()
            metalLayer.isOpaque = true
            self.layer.addSublayer(metalLayer)
            metalLayer.frame = bounds
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let metalLayer else { return }
        let srcW = area.width > 8 ? area.width : bounds.width
        let srcH = area.height > 8 ? area.height : bounds.height
        guard srcW >= 8, srcH >= 8 else { return }
        let scale = window?.screen.scale ?? UIScreen.main.scale
        let fbW = max(16, Int((srcW * scale).rounded()))
        let fbH = max(16, Int((srcH * scale).rounded()))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Always size the layer to the packed area, even if this view is later
        // clipped or wrapped. Shrinking the frame / setting contentsRect stalls
        // MoltenVK present (emu=0, black LCDs).
        metalLayer.frame = CGRect(origin: .zero, size: CGSize(width: srcW, height: srcH))
        metalLayer.contentsScale = scale
        if fbW > 0 && fbH > 0 {
            metalLayer.drawableSize = CGSize(width: fbW, height: fbH)
        }
        CATransaction.commit()
        guard fbW != lastFbW || fbH != lastFbH else { return }
        lastFbW = fbW
        lastFbH = fbH
        #if DEBUG
        NSLog("TwinPlay 3DS pre-layout surface fb=%dx%d scale=%.1f bounds=%.0fx%.0f area=%.0fx%.0f",
              fbW, fbH, scale, bounds.width, bounds.height, area.width, area.height)
        #endif
        session?.core.setN3DSSurfaceWidth(fbW, height: fbH, scale: Float(scale))
    }
}


// MARK: - Folium-style two-layer 3DS present (isolated)

/// Two destination CAMetalLayers, one in each Duo half. Azahar keeps a hidden
/// 400x480 stacked swapchain; we blit each screen out only after both dest
/// drawableSizes are nonzero, then set present_ready so the core starts.
struct N3DSDualMetalHostView: UIViewRepresentable {
    let session: EmulatorSession
    let top: CGRect
    let bottom: CGRect

    func makeUIView(context: Context) -> N3DSDualMetalHostUIView {
        let v = N3DSDualMetalHostUIView()
        v.session = session
        v.topRect = top
        v.botRect = bottom
        return v
    }

    func updateUIView(_ uiView: N3DSDualMetalHostUIView, context: Context) {
        uiView.session = session
        uiView.topRect = top
        uiView.botRect = bottom
        uiView.setNeedsLayout()
    }
}

final class N3DSDualMetalHostUIView: UIView {
    weak var session: EmulatorSession?
    var topRect: CGRect = .zero
    var botRect: CGRect = .zero
    private let topView = N3DSDestMetalView()
    private let botView = N3DSDestMetalView()
    private var link: CADisplayLink?
    private var ready = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        addSubview(topView)
        addSubview(botView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            if link == nil {
                let l = CADisplayLink(target: self, selector: #selector(tick))
                l.add(to: .main, forMode: .common)
                link = l
            }
            setNeedsLayout()
        } else {
            link?.invalidate()
            link = nil
            setReady(false)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        topView.frame = topRect
        botView.frame = botRect
        topView.updateDrawable()
        botView.updateDrawable()
        setReady(topView.ready && botView.ready)
    }

    private func setReady(_ ok: Bool) {
        guard ready != ok else { return }
        ready = ok
        session?.core.setN3DSPresentReady(ok)
        #if DEBUG
        NSLog("TwinPlay 3DS present_ready=%d top=%.0fx%.0f bot=%.0fx%.0f", ok ? 1 : 0,
              topView.metal.drawableSize.width, topView.metal.drawableSize.height,
              botView.metal.drawableSize.width, botView.metal.drawableSize.height)
        #endif
    }

    @objc private func tick() {
        guard ready, let session else { return }
        let t = topView.metal
        let b = botView.metal
        // scale=1: dest rects are already in drawable pixels.
        session.core.compositeN3DS(toLayer: Unmanaged.passUnretained(t).toOpaque(), scale: 1,
                                   topX: 0, topY: 0, topW: Float(t.drawableSize.width), topH: Float(t.drawableSize.height),
                                   bottomX: 0, bottomY: 0, bottomW: 0, bottomH: 0)
        session.core.compositeN3DS(toLayer: Unmanaged.passUnretained(b).toOpaque(), scale: 1,
                                   topX: 0, topY: 0, topW: 0, topH: 0,
                                   bottomX: 0, bottomY: 0, bottomW: Float(b.drawableSize.width), bottomH: Float(b.drawableSize.height))
    }
}

final class N3DSDestMetalView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metal: CAMetalLayer { layer as! CAMetalLayer }
    var ready: Bool { metal.drawableSize.width >= 16 && metal.drawableSize.height >= 16 }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = .black
        isUserInteractionEnabled = false
        metal.pixelFormat = .bgra8Unorm
        metal.framebufferOnly = true
        metal.isOpaque = true
        if let dev = MTLCreateSystemDefaultDevice() { metal.device = dev }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    func updateDrawable() {
        let scale = window?.screen.scale ?? UIScreen.main.scale
        let w = max(0, bounds.width * scale)
        let h = max(0, bounds.height * scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metal.contentsScale = scale
        if w >= 16 && h >= 16 { metal.drawableSize = CGSize(width: w, height: h) }
        CATransaction.commit()
    }
}
