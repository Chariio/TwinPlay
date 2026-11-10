// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import SwiftUI

/// In-game menu, shown as a sheet while the game is paused. Plain Form rows (no nested
/// Menus) so every option is a large, reliable tap target.
struct GameMenuView: View {
    @ObservedObject var session: EmulatorSession
    let onQuit: () -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var ra = RetroAchievements.shared

    @AppStorage("arrangement") private var arrangementRaw = ScreenArrangement.automatic.rawValue
    @AppStorage("controlsVisibility") private var controlsVisibilityRaw = ControlsVisibility.auto.rawValue
    @AppStorage("frameSkip") private var frameSkipRaw = FrameSkipSetting.auto.rawValue
    @AppStorage("frameBlend") private var frameBlend = false
    @AppStorage("screenIntegerSnap") private var integerSnap = false
    @AppStorage("renderer") private var renderer = "metal"
    @AppStorage("skin") private var skinRaw = Skin.classicGray.rawValue
    @AppStorage("skinGBA") private var skinGBARaw = Skin.gbaIndigo.rawValue
    @AppStorage("skinNES") private var skinNESRaw = Skin.nesFog.rawValue
    @AppStorage("skinSNES") private var skinSNESRaw = Skin.snesFog.rawValue
    @AppStorage("skinN64") private var skinN64Raw = Skin.n64Original.rawValue
    @AppStorage("skinN3DS") private var skinN3DSRaw = Skin.n3dsPearl.rawValue
    @AppStorage("ffMute") private var ffMute = true
    @AppStorage(TouchSettings.scaleKey) private var touchScale = 1.0
    @AppStorage(TouchSettings.opacityKey) private var touchOpacity = 0.0
    @AppStorage(TouchSettings.hapticsKey) private var touchHaptics = true
    @AppStorage(TouchSettings.touchOnlyKey) private var dsTouchOnly = false
    @AppStorage(TouchSettings.stylusOffsetKey) private var stylusOffset = 0.0
    @AppStorage(TouchSettings.stylusCursorKey) private var stylusCursor = false
    @AppStorage("renderScale") private var renderScale = QualityDefaults.renderScale
    @AppStorage("displayFilter") private var filterRaw = DisplayFilter.sharpBilinear.rawValue

    @AppStorage("antiAlias") private var antiAlias = 1
    @AppStorage("textureFilter") private var textureFilter = false
    @AppStorage("autoQuality") private var autoQuality = true
    @AppStorage("gbPalette") private var gbPalette = "green"
    @AppStorage("gbColorCorrection") private var gbColorCorrection = true
    @State private var color = ColorAdjust.load()
    @State private var showSlots = false
    @State private var showControllers = false
    @State private var showSkins = false
    @State private var confirmQuit = false
    @State private var confirmRestart = false
    @State private var confirmDeleteSave = false
    @State private var saveType = 0
    @State private var saveInfo = ""

    private func slider(_ title: String, value: Binding<Float>, range: ClosedRange<Float>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(title.loc); Spacer(); Text(String(format: "%.2f", value.wrappedValue)).foregroundStyle(.secondary).monospacedDigit() }
            Slider(value: value, in: range)
        }
    }

    /// Plus-tier options keep their row visible with a lock; tapping opens the paywall.
    /// Frame timing and core status: developer builds only (never in Release / App Store).
    private var headStats: String? {
        #if DEBUG
        if !UserDefaults.standard.bool(forKey: "NDUOHideStats") {
            let t = [session.performance, session.status].filter { !$0.isEmpty }.joined(separator: "\n")
            return t.isEmpty ? nil : t
        }
        #endif
        return nil
    }

    private func lockTitle(_ t: String) -> String { Store.allows(.screenLayouts) ? t : String(localized: "🔒 \(t.loc) (Plus)") }

    /// "Best graphics @ 60 FPS": highest 3D resolution the device holds (3x on high-end, else 2x),
    /// Sharp Bilinear, Smooth 3D off, frame blending off, edge smoothing (no supersampling),
    /// frame skip off, fast-forward off, and Auto quality on so the resolution steps down if
    /// the game can't keep ~58+ fps. Rendering accuracy is unchanged.
    private func applyBest60() {
        renderScale = QualityDefaults.renderScale; session.setRenderScale(renderScale)
        filterRaw = DisplayFilter.sharpBilinear.rawValue; session.setDisplayFilter(.sharpBilinear)
        textureFilter = false; antiAlias = 1; autoQuality = true
        session.applyEnhancements()
        frameBlend = false; session.setFrameBlend(false)
        frameSkipRaw = FrameSkipSetting.off.rawValue; session.setFrameSkip(.off)
        session.fastForwardOn = false
        session.showToast(String(localized: "Best graphics @ 60 FPS: \(renderScale)x, Sharp Bilinear"))
        session.warnIfThrottled()
    }

    /// Best defaults for this device (see QualityDefaults).
    private func restoreBestVideo() {
        antiAlias = 1; textureFilter = false; autoQuality = true
        frameBlend = false; session.setFrameBlend(false)
        filterRaw = DisplayFilter.sharpBilinear.rawValue
        session.setDisplayFilter(.sharpBilinear)
        renderScale = QualityDefaults.renderScale
        session.setRenderScale(renderScale)
        session.applyEnhancements()
    }

    static let saveTypes = ["Automatic", "EEPROM 0.5 KB", "EEPROM 8 KB", "EEPROM 64 KB", "EEPROM 128 KB",
                            "FRAM 32 KB", "Flash 256 KB", "Flash 512 KB", "Flash 1 MB", "Flash 8 MB"]

    /// GBA save chips (tags use the same numbers as the DS list where the size matches).
    static let gbaSaveTypes: [(Int, String)] = [(0, "Automatic"), (1, "EEPROM 512 B"), (2, "EEPROM 8 KB"),
                                                (5, "SRAM 32 KB"), (7, "Flash 64 KB"), (8, "Flash 128 KB")]
    private var saveTypeOptions: [(Int, String)] {
        if session.system == .nes || session.system == .snes || session.system == .n64 || session.system == .n3ds { return [] }
        return session.isGBA ? Self.gbaSaveTypes : Array(Self.saveTypes.enumerated()).map { ($0.offset, $0.element) }
    }
    private var skinBinding: Binding<String> {
        switch session.system.skinSystem {
        case .nes:
            return Binding(get: { Skin.current(for: .nes, raw: skinNESRaw).rawValue }, set: { if Skin(rawValue: $0)?.isFree == true || Store.gate(.extraSkins) { skinNESRaw = $0 } })
        case .snes:
            return Binding(get: { Skin.current(for: .snes, raw: skinSNESRaw).rawValue }, set: { if Skin(rawValue: $0)?.isFree == true || Store.gate(.extraSkins) { skinSNESRaw = $0 } })
        case .n64:
            return Binding(get: { Skin.current(for: .n64, raw: skinN64Raw).rawValue }, set: { if Skin(rawValue: $0)?.isFree == true || Store.gate(.extraSkins) { skinN64Raw = $0 } })
        case .n3ds:
            return Binding(get: { Skin.current(for: .n3ds, raw: skinN3DSRaw).rawValue }, set: { if Skin(rawValue: $0)?.isFree == true || Store.gate(.extraSkins) { skinN3DSRaw = $0 } })
        case .ds:
            return Binding(get: { Skin.current(for: .ds, raw: skinRaw).rawValue }, set: { if Skin(rawValue: $0)?.isFree == true || Store.gate(.extraSkins) { skinRaw = $0 } })
        default:
            return Binding(get: { Skin.current(for: .gba, raw: skinGBARaw).rawValue }, set: { if Skin(rawValue: $0)?.isFree == true || Store.gate(.extraSkins) { skinGBARaw = $0 } })
        }
    }
    private var skinRowTitle: String {
        switch session.system {
        case .gb, .gbc: return "Game Boy skin"
        case .gba: return "GBA skin"
        case .nes: return "NES skin"
        case .snes: return "Super NES skin"
        case .n64: return "N64 skin"
        case .n3ds: return "3DS skin"
        case .ds: return "DS skin"
        }
    }

    @State private var showAbout = false
    @State private var showIcons = false
    @State private var page = "main"
    @State private var dialog: String?          // "quit", "restart", "deleteSave"
    @State private var showCheats = false
    @AppStorage("showFPS") private var showFPS = false
    @AppStorage("fpsCorner") private var fpsCorner = FPSCorner.topLeading.rawValue
    @AppStorage("fpsFrameTime") private var fpsFrameTime = false

    /// Binding<Int> (index) over a list of values for a choice row.
    private func choice<T: Equatable>(_ values: [T], _ b: Binding<T>) -> Binding<Int> {
        Binding(get: { values.firstIndex(of: b.wrappedValue) ?? 0 },
                set: { i in if values.indices.contains(i) { b.wrappedValue = values[i] } })
    }

    /// Category pages of the pause menu (id, title, SF Symbol).
    static let categories: [(String, String, String)] = [
        ("save", "Save / Load", "square.and.arrow.down.on.square"),
        ("graphics", "Graphics", "sparkles.tv"),
        ("screens", "Screens & Skins", "rectangle.split.1x2"),
        ("controls", "Controls", "gamecontroller"),
        ("speed", "Speed", "forward"),
        ("system", "System & more", "gearshape"),
    ]
    private func pageTitle(_ p: String) -> String {
        if p == "colour" { return "Colour" }
        return Self.categories.first { $0.0 == p }?.1 ?? "Paused"
    }

    /// Top level: the game actions (Quit stays right at the top), then one row per category.
    private func takeScreenshot() {
        let img = session.screenshotImage()
        Task { @MainActor in
            do { try await GameCapture.saveScreenshot(img); session.showToast(String(localized: "Screenshot saved to Photos")) }
            catch { session.showToast(error.localizedDescription) }
        }
    }
    private func toggleRecording() {
        Task { @MainActor in
            do {
                if session.isRecording {
                    session.isRecording = false
                    try await GameCapture.stopRecording()
                    session.showToast(String(localized: "Video saved to Photos"))
                } else {
                    try await GameCapture.startRecording()
                    session.isRecording = true
                    dismiss()                                   // back to the game while recording
                }
            } catch { session.isRecording = false; session.showToast(error.localizedDescription) }
        }
    }

    private var mainSections: [PadSection] {
        var out: [PadSection] = []
        out.append(PadSection(title: "", rows: [
            PadRow(id: "head", title: session.title, subtitle: headStats, kind: .info),
            PadRow(id: "resume", title: "Resume game", icon: "play.fill", kind: .action { dismiss() }),
            PadRow(id: "qsave", title: "Quick save", subtitle: "Slot 1", icon: "square.and.arrow.down", kind: .action {
                session.saveState(slot: 1) { _ in }; UINotificationFeedbackGenerator().notificationOccurred(.success) }),
            PadRow(id: "qload", title: "Quick load", subtitle: "Slot 1", icon: "square.and.arrow.up", kind: .action {
                session.loadState(slot: 1) { ok in if ok { dismiss() } } }),
            PadRow(id: "quit", title: "Quit game", subtitle: "Writes the auto save slot", icon: "xmark.circle", destructive: true, kind: .action { dialog = "quit" }),
            PadRow(id: "restart", title: "Restart game", icon: "arrow.counterclockwise", kind: .action { dialog = "restart" }),
            PadRow(id: "hold", title: "Hold Buttons…",
                   subtitle: session.holdState.held.isEmpty ? "Pick buttons that stay pressed until you tap them again." : String(localized: "Holding \(session.holdState.held.names)"),
                   icon: "pin", kind: .action { session.beginHoldSelection(); dismiss() }),
        ]))
        out.append(PadSection(title: "Capture & cheats", rows: [
            PadRow(id: "shot", title: "Take screenshot", subtitle: "Saved to Photos", icon: "camera", kind: .action { takeScreenshot() }),
            PadRow(id: "rec", title: session.isRecording ? "Stop recording" : "Record video",
                   subtitle: session.isRecording ? "Saves the video to Photos" : "Picture and game sound, saved to Photos",
                   icon: session.isRecording ? "stop.circle" : "record.circle", kind: .action { toggleRecording() }),
            PadRow(id: "ra", title: "RetroAchievements",
                   subtitle: ra.gameProgress.map { $0 + (ra.hardcore ? " · " + "Hardcore".loc : "") }
                       ?? (ra.hasSavedLogin ? "No achievements found for this game" : "Sign in from Settings > RetroAchievements"),
                   icon: "medal", kind: .info),
            PadRow(id: "cheats", title: "Cheats", subtitle: session.system == .nes || session.system == .snes ? "Not available for this system yet" : (session.cheats.isEmpty ? nil : String(localized: "\(session.cheats.filter(\.enabled).count) on")),
                   icon: "wand.and.stars", chevron: session.system != .nes && session.system != .snes, kind: .action {
                       if session.system == .nes || session.system == .snes { session.showToast("Cheats aren't available for this system yet"); return }
                       showCheats = true
                   }),
        ]))
        out.append(PadSection(title: "Settings", rows: Self.categories.map { c in
            PadRow(id: "cat-" + c.0, title: c.1, icon: c.2, chevron: true, kind: .action { page = c.0 })
        }))
        return out
    }

    private func sections(for p: String) -> [PadSection] {
        switch p {
        case "graphics": return graphicsSections
        case "screens": return screensSections
        case "controls": return controlsSections
        case "save": return saveSections
        case "speed": return speedSections
        case "system": return systemSections
        case "colour": return colourSections
        default: return mainSections
        }
    }

    private var graphicsSections: [PadSection] {
        var gfx: [PadRow] = [
            PadRow(id: "best60", title: "Best graphics @ 60 FPS", subtitle: "One tap: sharpest settings that hold 60 fps. Lowers 3D resolution automatically if needed.",
                   icon: "bolt.fill", kind: .action { applyBest60(); dismiss() }),
            PadRow(id: "recommended", title: "Use recommended settings",
                   subtitle: "On by default for this game. Off keeps the graphics choices you set.",
                   icon: "wand.and.stars", kind: .toggle(Binding(get: { session.useRecommended }, set: { session.setUseRecommended($0) }))),
        ]
        if session.system == .ds {
            gfx.append(PadRow(id: "res", title: "3D resolution", icon: "cube", kind: .choice((1...4).map { $0 == QualityDefaults.renderScale ? String(localized: "\($0)x (recommended)") : "\($0)x" },
                choice(Array(1...4), Binding(get: { session.useRecommended ? session.activeRenderScale : renderScale }, set: { session.setRenderScale($0) })))))
        }
        gfx.append(PadRow(id: "filter", title: "Screen filter", icon: "camera.filters", kind: .choice(DisplayFilter.allCases.map(\.label),
            choice(DisplayFilter.allCases.map(\.rawValue), Binding(get: { session.useRecommended ? session.appliedFilterRaw : filterRaw }, set: {
                session.setDisplayFilter(DisplayFilter(rawValue: $0) ?? .sharpBilinear) })))))
        if session.system == .ds {
            gfx.append(PadRow(id: "tex", title: "Smooth 3D textures (slower)", icon: "square.on.square", kind: .toggle(
                Binding(get: { textureFilter }, set: { textureFilter = $0; session.applyEnhancements() }))))
        }
        if session.isGameBoy {
            if session.system == .gb {
                gfx.append(PadRow(id: "gbpal", title: "Game Boy shades", icon: "circle.lefthalf.filled", kind: .choice(["Green", "Gray"],
                    choice(["green", "gray"], Binding(get: { gbPalette }, set: { gbPalette = $0; session.refreshGameBoyVideo() })))))
            } else {
                gfx.append(PadRow(id: "gbcc", title: "Colour correction", subtitle: "Matches the Game Boy Color screen instead of full saturation.",
                                  icon: "eyedropper.halffull", kind: .toggle(Binding(get: { gbColorCorrection }, set: { gbColorCorrection = $0; session.refreshGameBoyVideo() }))))
            }
        }
        gfx.append(PadRow(id: "blend", title: "Frame blending", subtitle: "Smooths games that flicker sprites on purpose (shadows, transparency). Adds slight motion blur.",
                          icon: "square.2.layers.3d", kind: .toggle(Binding(get: { frameBlend }, set: { frameBlend = $0; session.setFrameBlend($0) }))))
        gfx.append(PadRow(id: "fps", title: "Show FPS", icon: "speedometer", kind: .toggle(Binding(get: { showFPS && Store.allows(.fpsOverlay) }, set: { if !$0 || Store.gate(.fpsOverlay) { showFPS = $0 } }))))
        if showFPS && Store.allows(.fpsOverlay) {
            gfx.append(PadRow(id: "fpscorner", title: "FPS corner", icon: "rectangle.inset.topleft.filled", kind: .choice(FPSCorner.allCases.map(\.label),
                choice(FPSCorner.allCases.map(\.rawValue), $fpsCorner))))
            gfx.append(PadRow(id: "fpsms", title: "Show frame time", icon: "timer", kind: .toggle($fpsFrameTime)))
        }
        if session.system == .ds {
            gfx.append(PadRow(id: "autoq", title: "Auto quality", subtitle: "Lowers the 3D resolution if the game can't keep 60 fps.", icon: "gauge", kind: .toggle($autoQuality)))
            gfx.append(PadRow(id: "aa", title: "3D anti-aliasing", icon: "circle.grid.cross", kind: .choice(["Off", "Edge smoothing", "Supersampling 2x (slow)"],
                Binding(get: { antiAlias }, set: { antiAlias = $0; session.applyEnhancements() }))))
        }
        if !session.isTestMode && session.system == .ds {
            gfx.append(PadRow(id: "wide", title: "Widescreen 3D (experimental)", subtitle: "This game only. 2D graphics are stretched; objects may pop in at the sides.",
                              icon: "rectangle.expand.vertical", kind: .toggle(Binding(get: { session.widescreen }, set: { session.setWidescreen($0) }))))
        }
        gfx.append(PadRow(id: "colour", title: "Colour adjustments", icon: "paintpalette", chevron: true, kind: .action { page = "colour" }))
        gfx.append(PadRow(id: "best", title: "Restore best settings", icon: "arrow.uturn.backward", kind: .action { restoreBestVideo() }))
        return [PadSection(title: "Graphics", footer: session.activeRenderScale < renderScale
                           ? String(localized: "Auto quality is using \(session.activeRenderScale)x right now to keep the game smooth.") : nil, rows: gfx)]
    }

    private var screensSections: [PadSection] {
        var scr: [PadRow] = [
            PadRow(id: "skins", title: "Skins…", subtitle: "Colour and finish of the whole play area, with a live preview.",
                   icon: "paintpalette.fill", chevron: true, kind: .action { showSkins = true }),
        ]
        if !session.isGBA {
            scr.append(PadRow(id: "smode", title: lockTitle("Screen mode"), subtitle: "Remembered for this game. An open iPhone Duo always shows both screens.",
                              icon: "rectangle.on.rectangle", kind: .choice(ScreenMode.allCases.map(\.label),
                choice(ScreenMode.allCases.map(\.rawValue), Binding(get: { session.screenMode.rawValue },
                    set: { if Store.gate(.screenLayouts) { session.setScreenMode(ScreenMode(rawValue: $0) ?? .both) } })))))
            if session.screenMode != .both {
                scr.append(PadRow(id: "swap", title: "Show the hidden screen", subtitle: "Temporary swap (also the button at the top, or a controller shortcut).",
                                  icon: "rectangle.2.swap", kind: .toggle($session.peekHidden)))
            }
        }
        scr.append(editLayoutRow)
        scr.append(PadRow(id: "isnap", title: "Integer scaling", icon: "square.grid.3x3", kind: .toggle($integerSnap)))
        if !session.isGBA {
            scr.append(PadRow(id: "arr", title: "Layout", icon: "rectangle.split.1x2", kind: .choice(ScreenArrangement.allCases.map(\.label),
                choice(ScreenArrangement.allCases.map(\.rawValue), $arrangementRaw))))
        }
        let skins = Skin.skins(for: session.system)
        scr.append(PadRow(id: "skin", title: skinRowTitle, icon: "paintbrush", kind: .choice(skins.map(\.label),
            choice(skins.map(\.rawValue), skinBinding))))
        return [PadSection(title: "Screens", rows: scr)]
    }

    /// Free for everyone: move and resize the screens and the on-screen buttons.
    private var editLayoutRow: PadRow {
        PadRow(id: "elayout", title: "Edit Layout…", subtitle: "Move and resize the screens and buttons. Saved for this console and orientation.",
               icon: "rectangle.3.group", chevron: true, kind: .action { session.editSizeRequested = true; dismiss() })
    }

    private var controlsSections: [PadSection] {
        [PadSection(title: "Controls", footer: "Button mapping, controller shortcuts (screen mode, quick save, fast-forward…) and joystick calibration are on the controller screen.", rows: [
            editLayoutRow,
            PadRow(id: "pads", title: "Button mapping & shortcuts…", icon: "gamecontroller", chevron: true, kind: .action { showControllers = true }),
            PadRow(id: "stick", title: "Joystick calibration…", icon: "scope", chevron: true, kind: .action { showControllers = true }),
            PadRow(id: "osc", title: "On-screen controls", icon: "hand.tap", kind: .choice(ControlsVisibility.allCases.map(\.label),
                choice(ControlsVisibility.allCases.map(\.rawValue), $controlsVisibilityRaw))),
        ])] + touchSections
    }

    /// Size / opacity / haptics for the on-screen buttons, and the DS touch-screen options.
    private var touchSections: [PadSection] {
        var rows = [
            PadRow(id: "tsize", title: "Button size", icon: "arrow.up.left.and.arrow.down.right",
                   kind: .choice(["Small", "Standard", "Large", "Extra large"], choice([0.85, 1.0, 1.15, 1.3], nearest($touchScale, [0.85, 1.0, 1.15, 1.3])))),
            PadRow(id: "topac", title: "Button opacity", icon: "circle.lefthalf.filled",
                   kind: .choice(["Skin default", "30%", "50%", "70%", "100%"], choice([0.0, 0.3, 0.5, 0.7, 1.0], nearest($touchOpacity, [0.0, 0.3, 0.5, 0.7, 1.0])))),
            PadRow(id: "thapt", title: "Haptic feedback", icon: "iphone.radiowaves.left.and.right", kind: .toggle($touchHaptics)),
        ]
        if !session.isGBA {
            rows += [
                PadRow(id: "tonly", title: "Touch only (hide buttons)", subtitle: "For stylus games: the bottom screen is unobstructed. Also the hand button at the top.",
                       icon: "hand.point.up.left", kind: .toggle($dsTouchOnly)),
                PadRow(id: "toff", title: "Touch point", subtitle: "Raise the touch point above your finger so it does not hide what you tap.",
                       icon: "scope", kind: .choice(["Under the finger", "Slightly above (6pt)", "Above (12pt)", "Well above (20pt)"],
                                                    choice([0.0, 6.0, 12.0, 20.0], nearest($stylusOffset, [0.0, 6.0, 12.0, 20.0])))),
                PadRow(id: "tcur", title: "Show touch cursor", subtitle: "A crosshair where the stylus touches the DS screen.", icon: "plus.viewfinder", kind: .toggle($stylusCursor)),
            ]
        }
        return [PadSection(title: "Touch controls", footer: "Slide between buttons without lifting your finger; touch between A and B to press both. Start and Select only react to a direct tap.", rows: rows)]
    }

    /// Snaps a stored value to the closest preset so the choice row always shows a selection.
    private func nearest(_ b: Binding<Double>, _ values: [Double]) -> Binding<Double> {
        Binding(get: { values.min { abs($0 - b.wrappedValue) < abs($1 - b.wrappedValue) } ?? b.wrappedValue },
                set: { b.wrappedValue = $0 })
    }

    private var saveSections: [PadSection] {
        var out = [PadSection(title: "Save states", footer: "Save states capture the exact moment. Quick save and load use slot 1.", rows: [
            PadRow(id: "qsave", title: "Quick save (slot 1)", icon: "square.and.arrow.down", kind: .action {
                session.saveState(slot: 1) { _ in }; UINotificationFeedbackGenerator().notificationOccurred(.success) }),
            PadRow(id: "qload", title: "Quick load (slot 1)", icon: "square.and.arrow.up", kind: .action { session.loadState(slot: 1) { ok in if ok { dismiss() } } }),
            PadRow(id: "slots", title: "All save slots…", icon: "square.stack", chevron: true, kind: .action { showSlots = true }),
        ])]
        if session.isGameBoy {
            out.append(PadSection(title: "Save file (in-game saves)", footer: saveInfo.isEmpty ? nil : saveInfo, rows: [
                PadRow(id: "delsave", title: "Delete save data…", icon: "trash", destructive: true, kind: .action { dialog = "deleteSave" }),
            ]))
        } else if session.system == .nes || session.system == .snes || session.system == .n64 || session.system == .n3ds {
            out.append(PadSection(title: "Save file (in-game saves)", footer: saveInfo.isEmpty ? "Battery saves are written automatically." : saveInfo, rows: [
                PadRow(id: "delsave", title: "Delete save data…", icon: "trash", destructive: true, kind: .action { dialog = "deleteSave" }),
            ]))
        } else if !session.isTestMode {
            let opts = saveTypeOptions
            out.append(PadSection(title: "Save file (in-game saves)",
                                  footer: saveInfo.isEmpty ? "Automatic detection works for most games. Change it only if the game reports save errors." : saveInfo,
                                  rows: [
                PadRow(id: "chip", title: "Save chip", icon: "memorychip", kind: .choice(opts.map(\.1),
                    choice(opts.map(\.0), Binding(get: { saveType }, set: { saveType = $0; session.setSaveTypeOverride($0) })))),
                PadRow(id: "delsave", title: "Delete save data…", icon: "trash", destructive: true, kind: .action { dialog = "deleteSave" }),
            ]))
        }
        return out
    }

    private var speedSections: [PadSection] {
        [PadSection(title: "Speed", rows: [
            PadRow(id: "ffspeed", title: "Fast-forward speed", icon: "forward", kind: .choice(["x2", "x3", "Unlimited"], choice([2, 3, 0], $session.fastForwardSpeed))),
            PadRow(id: "ffmute", title: "Sound while fast", icon: "speaker.wave.2", kind: .choice(["Mute", "Play (higher pitch)"],
                choice([true, false], Binding(get: { ffMute }, set: { ffMute = $0; session.fastForwardOn = session.fastForwardOn })))),
            PadRow(id: "skip", title: "Frame skip", icon: "forward.frame", kind: .choice(FrameSkipSetting.allCases.map(\.label),
                choice(FrameSkipSetting.allCases.map(\.rawValue), Binding(get: { session.useRecommended ? session.appliedFrameSkipRaw : frameSkipRaw }, set: {
                    session.setFrameSkip(FrameSkipSetting(rawValue: $0) ?? .auto) })))),
        ])]
    }

    private var systemSections: [PadSection] {
        [PadSection(title: "System", rows: [
            PadRow(id: "renderer", title: "Renderer (next game)", icon: "cpu", kind: .choice(["Metal", "Core Graphics"], choice(["metal", "cg"], $renderer))),
            PadRow(id: "upgrade", title: Store.tier == .pro ? "TwinPlay Pro ✓" : "Upgrade (Plus / Pro)", icon: "star.circle", chevron: true, kind: .action { PaywallPresenter.present() }),
            PadRow(id: "appicon", title: "App Icon", icon: "app.badge", chevron: true, kind: .action { showIcons = true }),
            PadRow(id: "about", title: "About & Credits", icon: "info.circle", chevron: true, kind: .action { showAbout = true }),
        ])]
    }

    private var colourSections: [PadSection] {
        [PadSection(title: "Colour", rows: [
            PadRow(id: "bri", title: "Brightness", kind: .slider($color.brightness, -0.5...0.5, 0.05)),
            PadRow(id: "con", title: "Contrast", kind: .slider($color.contrast, 0.5...1.5, 0.05)),
            PadRow(id: "sat", title: "Saturation", kind: .slider($color.saturation, 0...2, 0.1)),
            PadRow(id: "gam", title: "Gamma", kind: .slider($color.gamma, 0.5...2, 0.05)),
            PadRow(id: "lcd", title: "LCD colour correction", kind: .toggle($color.lcdCorrection)),
            PadRow(id: "reset", title: "Reset colours", icon: "arrow.uturn.backward", kind: .action { color = ColorAdjust() }),
        ])]
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if page != "main" {
                    PadFormView(sections: sections(for: page), scope: "pause-" + page, onBack: { page = page == "colour" ? "graphics" : "main" })
                        .id(page)
                        .transition(.move(edge: .trailing))
                } else {
                    PadFormView(sections: mainSections, scope: "pause", onBack: { dismiss() },
                                onOther: { e, _ in if e == .menu { dismiss(); return true }; return false })
                }
                if let d = dialog { dialogView(d) }
            }
            .animation(.easeInOut(duration: 0.2), value: page)
            .animation(.easeInOut(duration: 0.15), value: dialog)
            .onChange(of: color) { session.setColor($0) }
            .safeAreaInset(edge: .bottom) {
                ControllerHintBar(items: [(.up, "Move"), (.a, "Select"), (.left, "Change"), (.l, "Section"), (.b, page == "main" ? "Resume" : "Back")])
            }
            .navigationTitle(pageTitle(page).loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                if page != "main" {
                    ToolbarItem(placement: .cancellationAction) { Button { page = page == "colour" ? "graphics" : "main" } label: { Label("Back", systemImage: "chevron.left") } }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Resume") { dismiss() } }
            }
            .sheet(isPresented: $showAbout) { AboutView() }
            .sheet(isPresented: $showIcons) { AppIconPickerView() }
            .sheet(isPresented: $showSlots) { SaveSlotsView(session: session) }
            .sheet(isPresented: $showCheats) { CheatsView(session: session) }
            .sheet(isPresented: $showControllers) { ControllerSettingsView(manager: session.controllers) }
            .sheet(isPresented: $showSkins) {
                SkinPickerView(initialSystem: session.system,
                               screen: session.core.copyScreenImage(0).map { UIImage(cgImage: $0) })
            }
            .onAppear { saveType = session.saveTypeOverride; session.saveInfo { saveInfo = $0 } }
            #if DEBUG
            // Testing aid (store screenshots): -TwinPlaySeedCheats YES adds two example entries if the
            // game has none (one is the no-op AR "D2000000 00000000"); -TwinPlayOpenCheats YES opens Cheats.
            .onAppear {
                let d = UserDefaults.standard
                if d.bool(forKey: "TwinPlaySeedCheats"), session.cheats.isEmpty {
                    let ex: [CheatEntry] = session.system == .ds
                        ? [CheatEntry(name: "My code", code: "D2000000 00000000"), CheatEntry(name: "Second code", code: "D2000000 00000000", enabled: false)]
                        : session.isGBA ? [CheatEntry(name: "My code", code: "00000000 0000", enabled: false)]
                        : [CheatEntry(name: "My code", code: "01FFC0C0", enabled: false), CheatEntry(name: "Second code", code: "01FFC1C0", enabled: false)]
                    session.setCheats(ex)
                }
                if d.bool(forKey: "TwinPlayOpenCheats") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { showCheats = true } }
            }
            #endif
        }
        .presentationDetents([.large])
    }

    @ViewBuilder private func dialogView(_ d: String) -> some View {
        switch d {
        case "quit":
            PadDialog(title: "Quit this game?", message: "The auto save slot is written first.", buttons: [
                PadDialogButton(title: "Quit", destructive: true) { onQuit() },
                PadDialogButton(title: "Cancel", cancel: true) {},
            ]) { dialog = nil }
        case "restart":
            PadDialog(title: "Restart this game?", message: "Unsaved progress is lost.", buttons: [
                PadDialogButton(title: "Restart", destructive: true) { session.reset(); dismiss() },
                PadDialogButton(title: "Cancel", cancel: true) {},
            ]) { dialog = nil }
        default:
            PadDialog(title: "Delete the save data?", message: "The game starts with empty save memory. A backup of the old file is kept (.sav.bak in the Saves folder).", buttons: [
                PadDialogButton(title: "Delete and restart", destructive: true) { session.deleteSaveData(); dismiss() },
                PadDialogButton(title: "Cancel", cancel: true) {},
            ]) { dialog = nil }
        }
    }
}
