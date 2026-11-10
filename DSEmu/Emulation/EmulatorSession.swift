// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import Foundation
import QuartzCore
import UIKit

/// Owns one running core: the emulation thread, audio and input routing.
#if DEBUG
/// Launch-arg test hooks. They are copied into UserDefaults so devicectl can pass
/// `-Key Value` pairs, but leftover values used to survive a normal SpringBoard
/// launch and then press buttons by themselves (TPTestPressStartA was still
/// mashing Start and A after Charlie opened the game from the icon).
enum DebugLaunchArgs {
    static let hookKeys: [String] = [
        "TPAutoBoot", "TwinPlayAutoOpen", "TwinPlayAutoOpenDelay", "TwinPlayImportDir",
        "TPTestPause", "TwinPlayTestPause",
        "TPTestPressA", "TwinPlayTestPressA", "TPTestPressADelay", "TPTestPressACount",
        "TPTestPressAOnly", "TPTestPressStartA",
        "TPTestHoldStick", "TwinPlayTestHoldStick",
        "TPTestHoldStickDelay", "TPTestHoldStickX", "TPTestHoldStickY",
        "TPTestHoldStick2Delay", "TPTestHoldStick2X", "TPTestHoldStick2Y",
        "TPTestLoadSlot", "TwinPlayTestLoadSlot", "TPTestLoadSlotDelay", "TwinPlayTestLoadSlotDelay",
        "TwinPlayLoadStatePath",
        "TwinPlayLogFPS", "TwinPlayLogLayout",
        "TwinPlayOpenMenu", "TwinPlayEditLayout", "TwinPlayFakeRecording", "TwinPlayDumpWindows",
        "TwinPlayShowIcons", "TwinPlayShowSkins", "TwinPlayShowRetroAchievements",
        "TwinPlayShowSystem", "TwinPlayOpenSettings", "TwinPlayShowPaywall",
        "TwinPlayClassicFocus", "TwinPlayWidgetPreviews",
        "TwinPlayForceTouchControls", "TwinPlayShowTouchZones",
        "TwinPlayForceLandscape", "TwinPlayInnerPreview", "TwinPlayOuterPreview",
        "TwinPlayFoldPosture", "TwinPlayHingeAngle", "TwinPlayLidNoSettle", "TwinPlayFaceDown",
        "TwinPlayOpenColors", "TwinPlayDebugUnlock", "TwinPlayLibraryRoot",
    ]

    /// Apply only keys present on this process's argv; remove every hook that is not.
    static func sync() {
        let args = ProcessInfo.processInfo.arguments
        var present = Set<String>()
        var i = 1
        while i < args.count {
            let a = args[i]
            if a.hasPrefix("-"), a.count > 1, !a.hasPrefix("--") {
                let key = String(a.dropFirst())
                if i + 1 < args.count, !args[i + 1].hasPrefix("-") {
                    UserDefaults.standard.set(args[i + 1], forKey: key)
                    present.insert(key)
                    i += 2
                    continue
                }
            }
            i += 1
        }
        for key in hookKeys where !present.contains(key) {
            UserDefaults.standard.removeObject(forKey: key)
        }
        NSLog("TwinPlay TPTEST: argv=%@ (hooks without argv cleared)",
              args.dropFirst().joined(separator: " | "))
    }
}
#endif

final class EmulatorSession: ObservableObject, Identifiable {
    let id = UUID()
    let core: DSCoreBridge
    let title: String
    let isTestMode: Bool
    /// DS, Game Boy Advance, Game Boy or Game Boy Color (chosen from the file extension / header).
    let system: GameSystem
    /// One screen: the single-screen layouts. NES, Super NES and N64 are included; they are not GBA games.
    /// 3DS is dual-screen, same as DS.
    var isGBA: Bool { system.isSingleScreen }
    var isGameBoy: Bool { system.isGameBoy }
    /// Aspect ratio of the single screen.
    var singleAspect: CGFloat { system.screenAspect }
    let slots: SaveSlotStore

    @Published private(set) var status: String = ""
    /// e.g. "9.4 ms/frame · 60 fps · skip 0" (updated twice a second).
    @Published private(set) var performance: String = ""
    /// Metal presenter (nil = Core Graphics fallback, e.g. no Metal device).
    let presenter: FramePresenter?
    @Published var isPaused = false { didSet { applyRunState() } }
    private var appInactive = false
    /// A physical game controller is connected (drives auto-hiding of on-screen controls).
    @Published private(set) var controllerConnected = false
    /// Fast-forward speed: 1 = normal, 2, 3, or 0 = unlimited. `fastForwardOn` toggles it.
    @Published var fastForwardSpeed: Int = UserDefaults.standard.object(forKey: "ffSpeed") as? Int ?? 2 {
        didSet { UserDefaults.standard.set(fastForwardSpeed, forKey: "ffSpeed"); applySpeed() }
    }
    @Published var fastForwardOn = false { didSet { applySpeed() } }
    /// Briefly shown message (e.g. "Saved to slot 1").
    @Published var toast: String?
    /// Per-game cheats (user-entered).
    @Published private(set) var cheats: [CheatEntry] = []
    /// Gameplay video recording (ReplayKit) is running.
    @Published var isRecording = false
    /// Request from a controller shortcut to open the save-slot picker.
    @Published var showSlotsRequested = false
    /// Set when a controller button (touchpad, Share...) asks for the pause menu.
    @Published var showMenuRequested = false
    /// Emulated frames per second and last frame time (for the FPS overlay).
    @Published private(set) var emulatedFPS: Double = 0
    @Published private(set) var frameTimeMs: Double = 0
    private var fpsLastFrames: UInt64 = 0
    private var fpsLastTime = CACurrentMediaTime()
    private var fastForwardHeld = false

    /// Last usable packed 3DS swapchain still (top + bottom). The Vulkan path
    /// never fills the software framebuffer that `copyThumbnailImage()` reads.
    private let n3dsShotLock = NSLock()
    private var n3dsPackedShot: UIImage?

    let controllers = GameControllerManager()
    private let audio: AudioOutput
    private let control = LoopControl()
    private var thread: Thread?
    private var statusTimer: Timer?
    private var virtualButtons: DSButton = []
    private var backgroundObserver: NSObjectProtocol?
    private var activeObserver: NSObjectProtocol?

    /// The game file (RetroAchievements identifies the game by hashing it).
    private let romPath: String?
    var romURL: URL? { romPath.map { URL(fileURLWithPath: $0) } }
    /// `twinplay.recommended.<id>`. Empty until the ROM has loaded.
    private(set) var profileID = ""
    private var profileLocked = true
    private var didProbe3D = false
    /// While recommended settings are on, auto quality will not climb above this.
    private var scaleCeiling: Int?
    @Published private(set) var useRecommended = true
    @Published private(set) var appliedFilterRaw = DisplayFilter.sharpBilinear.rawValue
    @Published private(set) var appliedFrameSkipRaw = FrameSkipSetting.auto.rawValue

    init(romURL: URL?, statesDirectory: URL, saveURL: URL? = nil, biosURL: URL? = nil) throws {
        romPath = romURL?.path
        slots = SaveSlotStore(directory: statesDirectory,
                              gameFileName: romURL?.deletingPathExtension().lastPathComponent ?? "test-pattern")
        if let romURL {
            let gbSystem = DSCoreBridge.gameBoySystem(ofROMAt: romURL)
            let nes = gbSystem == 0 && DSCoreBridge.isNESROM(at: romURL)
            let snes = gbSystem == 0 && !nes && DSCoreBridge.isSNESROM(at: romURL)
            let n64 = gbSystem == 0 && !nes && !snes && DSCoreBridge.isN64ROM(at: romURL)
            let n3ds = gbSystem == 0 && !nes && !snes && !n64 && DSCoreBridge.is3DSROM(at: romURL)
            let gba = gbSystem == 0 && !nes && !snes && !n64 && !n3ds && DSCoreBridge.isGBAROM(at: romURL)
            if gbSystem != 0 {
                core = DSCoreBridge(kind: .gb)
                BIOSStore.shared.applyGameBoy(to: core, color: gbSystem == 3)
                try core.loadROM(at: romURL)
                system = core.isGameBoyColor ? .gbc : .gb
                Self.applyGameBoyVideo(core)
            } else if n64 || n3ds {
                core = DSCoreBridge(kind: n64 ? .n64 : .n3ds)
                if n3ds {
                    let raw = UserDefaults.standard.object(forKey: "n3dsCpuClockPercentage")
                    let clock: Int
                    if let n = raw as? Int { clock = n }
                    else if let s = raw as? String, let n = Int(s) { clock = n }
                    else { clock = 100 }
                    core.setN3DSCpuClockPercentage(clock)
                }
                try core.loadROM(at: romURL)
                system = n64 ? .n64 : .n3ds
            } else if nes || snes {
                core = DSCoreBridge(kind: nes ? .nes : .snes)
                try core.loadROM(at: romURL)
                system = nes ? .nes : .snes
            } else {
                system = gba ? .gba : .ds
                core = DSCoreBridge(kind: gba ? .gba : .interpreter)
                if let biosURL, !gba { core.setARM7BIOS(biosURL) }
                BIOSStore.shared.apply(to: core, gba: gba)
                try core.loadROM(at: romURL)
            }
            core.saveTypeOverride = UserDefaults.standard.integer(forKey: "saveType.\(core.gameCode)")
            if let saveURL { core.attachSaveFile(saveURL) }
            // The library's name for the game (its file name), not the ROM header's internal title.
            title = romURL.deletingPathExtension().lastPathComponent
            isTestMode = false
        } else {
            core = DSCoreBridge(kind: .testPattern)
            system = .ds
            title = "Test mode"
            isTestMode = true
        }
        audio = AudioOutput(core: core)
        let renderer = UserDefaults.standard.string(forKey: "renderer") ?? "metal"
        presenter = renderer == "metal" ? FramePresenter(core: core) : nil
        presenter?.singleScreenCrop = system.isSingleScreen
            ? CGSize(width: CGFloat(core.screenWidth) / 256, height: CGFloat(core.screenHeight) / 192) : nil
        controllers.useStickAsDpad = system != .n64 && system != .n3ds
        controllers.zOnTriggers = system == .n64
        // Leave a core for the emulation thread and one for the UI/audio.
        let cpus = ProcessInfo.processInfo.activeProcessorCount
        control.renderThreads = max(0, min(3, cpus - 2))
        control.frameSkipSetting = FrameSkipSetting(rawValue: UserDefaults.standard.string(forKey: "frameSkip") ?? "") ?? .auto
        controllers.onChange = { [weak self] in self?.controllerChanged() }
        controllers.onConnectionChange = { [weak self] connected in self?.controllerConnected = connected }
        controllerConnected = controllers.isConnected
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.suspendForBackground()
        }
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.resumeFromBackground()
        }
        QualityDefaults.register()
        let scale = UserDefaults.standard.object(forKey: "renderScale") as? Int ?? QualityDefaults.renderScale
        applyRenderScale(scale)
        presenter?.filter = DisplayFilter(rawValue: UserDefaults.standard.string(forKey: "displayFilter") ?? "") ?? .sharpBilinear
        presenter?.color = ColorAdjust.load()
        presenter?.frameBlend = UserDefaults.standard.bool(forKey: "frameBlend")
        widescreen = !isTestMode && system == .ds && UserDefaults.standard.bool(forKey: "widescreen.\(core.gameCode)")
        screenMode = !system.isSingleScreen && Store.allows(.screenLayouts) ? (ScreenMode(rawValue: UserDefaults.standard.string(forKey: "screenMode.\(core.gameCode)") ?? "") ?? .both) : .both
        cheats = CheatStore.load(cheatKey)
        applyCheats()
        #if DEBUG
        if let m = UserDefaults.standard.string(forKey: "NDUOScreenMode").flatMap(ScreenMode.init(rawValue:)), system == .ds { screenMode = m }
        #endif
        applyEnhancements()
        let ident = GameProfiles.identify(url: romURL, system: system, gameCode: core.gameCode)
        profileID = ident.primary
        useRecommended = isTestMode ? false : GameProfiles.isEnabled(ident.primary)
        appliedFilterRaw = presenter?.filter.rawValue ?? DisplayFilter.sharpBilinear.rawValue
        appliedFrameSkipRaw = control.frameSkipSetting.rawValue
        if useRecommended {
            let rec = GameProfiles.recommend(ident, system: system)
            profileLocked = rec.locked
            scaleCeiling = rec.scale
            applyRenderScale(rec.scale)
            applyFilter(DisplayFilter(rawValue: rec.filter) ?? .nearest, persist: false)
            applyFrameSkip(FrameSkipSetting(rawValue: rec.frameSkip) ?? .off, persist: false)
        }
    }

    /// Game Boy picture options (Settings > Game Boy): DMG shades and GBC colour correction.
    static func applyGameBoyVideo(_ core: DSCoreBridge) {
        let d = UserDefaults.standard
        let palette = d.string(forKey: "gbPalette") == "gray" ? 1 : 0
        let correct = d.object(forKey: "gbColorCorrection") as? Bool ?? true
        core.setGameBoyVideo(palette: palette, colorCorrection: correct)
    }

    /// Re-reads the Game Boy picture options (called when they change in the menu).
    func refreshGameBoyVideo() { guard isGameBoy else { return }; Self.applyGameBoyVideo(core) }

    deinit {
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        stop()
    }

    /// Writes the cartridge save to disk now (e.g. when the app goes to the background).
    func flushSave() { control.enqueue { [core] in core.flushSave() } }

    func start() {
        // Release the library loop before the game session takes .playback.
        MenuMusic.shared.stopForGameplay()
        guard thread == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.warnIfThrottled() }
        powerObserver = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.warnIfThrottled()
        }
        control.setRunning(true)
        let control = self.control
        presenter?.onVSync = { control.vsync.signal() }
        let rate: Double = {
            switch system {
            case .ds: return 59.8261
            case .nes, .snes: return 60.0988                     // NTSC
            case .n64, .n3ds: return 60
            default: return 59.7275                              // GBA/GB/GBC: 4.194 MHz / 70224 clocks
            }
        }()
        let t = Thread { [core, control] in EmulatorSession.loop(core: core, control: control, rate: rate) }
        t.name = "TwinPlay.emulation"
        t.qualityOfService = .userInteractive
        thread = t
        DSCoreBridge.setCrashContext("game \(core.gameCode) system \(system) scale \(activeRenderScale)")
        t.start()
        audio.start()
        #if DEBUG
        // devicectl does not reliably register numeric -Key Value pairs into UserDefaults.
        // Sync from this launch's argv only; leftover hooks from a previous session are cleared
        // so they cannot fire when Charlie opens the app from the icon.
        DebugLaunchArgs.sync()
        if UserDefaults.standard.bool(forKey: "TPTestPause") || UserDefaults.standard.bool(forKey: "TwinPlayTestPause") {
            NSLog("TwinPlay TPTEST: scheduling pause/resume cycle")
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self, self.control.isRunning else { return }
                NSLog("TwinPlay TPTEST: pausing")
                self.isPaused = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                    guard let self, self.control.isRunning else { return }
                    NSLog("TwinPlay TPTEST: resuming")
                    self.isPaused = false
                    NSLog("TwinPlay TPTEST: pause/resume cycle done")
                }
            }
        }
        func debugNum(_ key: String) -> Double? {
            let v = UserDefaults.standard.object(forKey: key)
            if let d = v as? Double { return d }
            if let i = v as? Int { return Double(i) }
            if let s = v as? String { return Double(s) }
            return nil
        }
        if UserDefaults.standard.bool(forKey: "TPTestPressA") || UserDefaults.standard.bool(forKey: "TwinPlayTestPressA") {
            // 3DS logos often need ~15-18s before A will dismiss them. DEBUG only.
            // MK7's logo asks to touch the touch screen; start earlier and prefer taps.
            let delay = debugNum("TPTestPressADelay") ?? 8
            let count = Int(debugNum("TPTestPressACount") ?? 16)
            NSLog("TwinPlay TPTEST: scheduling %d A presses after %.1fs", count, delay)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.debugPressA(remaining: count)
            }
        }
        // Standalone stick hold (does not require a successful slot load).
        if UserDefaults.standard.bool(forKey: "TPTestHoldStick") || UserDefaults.standard.bool(forKey: "TwinPlayTestHoldStick") {
            let d1 = debugNum("TPTestHoldStickDelay") ?? 50
            let x1 = debugNum("TPTestHoldStickX") ?? -0.85
            let y1 = debugNum("TPTestHoldStickY") ?? 0
            let d2 = debugNum("TPTestHoldStick2Delay") ?? 70
            let x2 = debugNum("TPTestHoldStick2X") ?? 0
            let y2 = debugNum("TPTestHoldStick2Y") ?? 0.85
            NSLog("TwinPlay TPTEST: will hold stick (%.2f,%.2f) after %.1fs, then (%.2f,%.2f) after %.1fs", x1, y1, d1, x2, y2, d2)
            DispatchQueue.main.asyncAfter(deadline: .now() + d1) { [weak self] in
                guard let self, self.control.isRunning else { return }
                self.touchStick = (Float(x1), Float(y1))
                self.pushAnalog()
                NSLog("TwinPlay TPTEST: holding stick (%.2f,%.2f)", x1, y1)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + d2) { [weak self] in
                guard let self, self.control.isRunning else { return }
                self.touchStick = (Float(x2), Float(y2))
                self.pushAnalog()
                NSLog("TwinPlay TPTEST: holding stick (%.2f,%.2f)", x2, y2)
            }
        }
        let loadSlotRaw = UserDefaults.standard.object(forKey: "TPTestLoadSlot") ?? UserDefaults.standard.object(forKey: "TwinPlayTestLoadSlot")
        let loadSlot: Int? = {
            if let i = loadSlotRaw as? Int { return i }
            if let s = loadSlotRaw as? String, let i = Int(s) { return i }
            if let d = loadSlotRaw as? Double { return Int(d) }
            return nil
        }()
        if let loadSlot {
            let delay = debugNum("TPTestLoadSlotDelay") ?? debugNum("TwinPlayTestLoadSlotDelay") ?? 10
            NSLog("TwinPlay TPTEST: will load slot %d after %.1fs", loadSlot, delay)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.control.isRunning else { return }
                self.loadState(slot: loadSlot) { ok in
                    NSLog("TwinPlay TPTEST: load slot %d %@", loadSlot, ok ? "ok" : "FAILED")
                    if ok, UserDefaults.standard.bool(forKey: "TPTestHoldStick") || UserDefaults.standard.bool(forKey: "TwinPlayTestHoldStick") {
                        self.touchStick = (0, 0.85)
                        self.pushAnalog()
                        NSLog("TwinPlay TPTEST: holding stick forward")
                    }
                }
            }
        }
        #endif
        #if DEBUG
        if let path = UserDefaults.standard.string(forKey: "TwinPlayLoadStatePath"), let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            control.enqueue { [core] in _ = core.loadState(data) }   // testing aid
        }
        #endif
        if let romPath, !isTestMode {
            let core = self.core, system = self.system
            Task { @MainActor [weak self] in
                RetroAchievements.shared.onToast = { [weak self] t in self?.showToast(t) }
                RetroAchievements.shared.startGame(path: romPath, system: system, core: core)
                _ = self
            }
        }
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let s = self.core.statusText
            if s != self.status { self.status = s }
            let p = self.control.performanceSnapshot()
            self.checkAutoQuality(msPerFrame: p.msPerFrame, frameSkip: p.frameSkip)
            var text = String(format: "%.1f ms/frame", p.msPerFrame)
            if let presenter = self.presenter { text += String(format: " · %.0f fps", presenter.displayedFPS) }
            text += " · skip \(p.frameSkip)"
            if text != self.performance { self.performance = text }
            let frames = self.system == .n3ds ? self.core.n3dsFrameCount : self.core.frameSequence, now = CACurrentMediaTime()
            let dt = now - self.fpsLastTime
            if dt > 0 { self.emulatedFPS = Double(frames &- self.fpsLastFrames) / dt }
            self.fpsLastFrames = frames; self.fpsLastTime = now
            self.frameTimeMs = p.msPerFrame
            #if DEBUG
            // Testing aid only (no UI): -TwinPlayLogFPS YES prints emulated/displayed fps to the console.
            if UserDefaults.standard.bool(forKey: "TwinPlayLogFPS") {
                let api = (self.system == .n3ds && self.core.n3dsUsingVulkan) ? "vk" : "cpu"
                if self.system == .n3ds {
                    var last = 0.0, mx = 0.0, p95 = 0.0
                    self.core.n3dsFrameTimingLastMs(&last, maxMs: &mx, p95Ms: &p95)
                    NSLog("TWINPLAYFPS emu=%.1f shown=%.1f ms=%.2f skip=%d api=%@ ft=%.2f max=%.2f p95=%.2f", self.emulatedFPS,
                          self.presenter?.displayedFPS ?? 0, p.msPerFrame, p.frameSkip, api, last, mx, p95)
                } else {
                    NSLog("TWINPLAYFPS emu=%.1f shown=%.1f ms=%.2f skip=%d api=%@", self.emulatedFPS,
                          self.presenter?.displayedFPS ?? 0, p.msPerFrame, p.frameSkip, api)
                }
            }
            #endif
            self.watchdog(now: now)
            self.probe3DIfNeeded()
        }
    }

    /// One check, after the game has had a moment to draw. Not called from the frame loop.
    private func probe3DIfNeeded() {
        guard system == .ds, useRecommended, !profileLocked, !didProbe3D, core.framesRun > 45 else { return }
        didProbe3D = true
        if core.polygonsSubmitted > 0 {
            if activeRenderScale < 2 { scaleCeiling = 2; applyRenderScale(2) }
        } else if activeRenderScale > 1 {
            scaleCeiling = 1
            applyRenderScale(1)
        }
    }

    // MARK: Stall watchdog

    private var wdFrames: UInt64 = 0, wdFramesTime: CFTimeInterval = 0
    private var wdShown: UInt64 = 0, wdShownTime: CFTimeInterval = 0
    private var wdLogged = false, wdFreezeLogged = false
    private var wdLivelocks: UInt64 = 0, wdPoolStalls: UInt64 = 0, wdPoolLogTime: CFTimeInterval = 0

    /// Detects a frozen picture. If the emulation thread keeps running but no new picture reaches
    /// the screen for 2 s, the presenter is rebuilt. If the emulation thread itself stops, the
    /// state is written to the diagnostics log so the cause can be found.
    private func watchdog(now: CFTimeInterval) {
        guard control.isRunning, !isPaused else { wdFramesTime = now; wdShownTime = now; return }
        let run = core.framesRun
        // Emulation thread stalled: silence the speaker (no repeating buffer) until it resumes.
        audio.setStalled(run == wdFrames && now - wdFramesTime > 0.4)
        // The game itself locked up (no CPU activity for 2 s while frames keep running): log the
        // hardware state and keep a snapshot so the exact moment can be replayed and fixed.
        if core.stuckFrames >= 120 {
            if !wdFreezeLogged {
                wdFreezeLogged = true
                control.enqueue { [core] in
                    let report = core.freezeReport()
                    let state = core.saveState()
                    let stamp = Int(Date().timeIntervalSince1970)
                    Self.diagnostic("game locked up (\(core.gameCode)): \(report)")
                    if let state, let dir = Self.logsDirectory() {
                        try? state.write(to: dir.appendingPathComponent("freeze-\(core.gameCode)-\(stamp).state"))
                    }
                }
            }
        } else if core.stuckFrames == 0 { wdFreezeLogged = false }
        // The core recovered a game stuck waiting for an interrupt (picture frozen, music playing):
        // record it with a snapshot so the moment can be replayed.
        let livelocks = core.irqLivelockRecoveries
        if livelocks != wdLivelocks {
            wdLivelocks = livelocks
            control.enqueue { [core] in
                Self.diagnostic("game stuck in an interrupt wait (\(core.gameCode)), recovered (#\(livelocks)): \(core.freezeReport())")
                if let state = core.saveState(), let dir = Self.logsDirectory() {
                    try? state.write(to: dir.appendingPathComponent("livelock-\(core.gameCode)-\(Int(Date().timeIntervalSince1970)).state"))
                }
            }
        }
        // 3D worker waits that needed the timed re-wake (at most one line every 10 s).
        let stalls = core.renderPoolStalls
        if stalls != wdPoolStalls, now - wdPoolLogTime > 10 {
            Self.diagnostic("3D workers slow/re-woken: \(stalls &- wdPoolStalls) waits >100 ms (total \(stalls)) scale=\(activeRenderScale)")
            wdPoolStalls = stalls; wdPoolLogTime = now
        }
        if run != wdFrames { wdFrames = run; wdFramesTime = now; wdLogged = false }
        else if now - wdFramesTime > 3, !wdLogged {
            wdLogged = true
            Self.diagnostic("emulation thread stalled: framesRun=\(run) seq=\(core.frameSequence) scale=\(activeRenderScale) mode=\(screenMode.rawValue) capture=\(core.captureInUse) poolStalls=\(core.renderPoolStalls)")
        }
        // Vulkan/MoltenVK presents through a CAMetalLayer, not FramePresenter.
        // shown stays 0, so the DS stall-rebuild would fire every 2s and can
        // cover or reset the Metal host view (black screens / hitches).
        if system == .n3ds && core.n3dsUsingVulkan {
            wdShownTime = now
            return
        }
        guard let presenter else { return }
        let shown = presenter.presentedSequence
        if shown != wdShown || core.frameSequence == shown { wdShown = shown; wdShownTime = now; return }
        if now - wdShownTime > 2 {
            Self.diagnostic("picture stalled: shown=\(shown) seq=\(core.frameSequence) lastTick=\(String(format: "%.1f", now - presenter.lastTick))s ago scale=\(activeRenderScale) mode=\(screenMode.rawValue) capture=\(core.captureInUse); presenter rebuilt")
            presenter.recover()
            wdShownTime = now
        }
    }

    static func logsDirectory() -> URL? {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let dir = docs.appendingPathComponent("Logs", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Appends a line to Documents/Logs/twinplay-diagnostics.log.
    static func diagnostic(_ line: String) {
        NSLog("TwinPlay: %@", line)
        guard let dir = logsDirectory() else { return }
        let url = dir.appendingPathComponent("twinplay-diagnostics.log")
        let text = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close() }
        else { try? Data(text.utf8).write(to: url) }
    }

    func stop() {
        if control.isRunning {
            autoSave()
            control.enqueue { [core] in core.flushSave() }
        }
        core.setEmulationPaused(true)
        presenter?.setActive(false)
        let hadThread = thread != nil
        control.setRunning(false)
        control.vsync.signal()
        control.vsync.signal()
        // The loop drains autoSave after isRunning becomes false. N64 state
        // saves wait up to 3 s for Mupen; calling shutDownCore before that
        // returns unloads plugins under a live save — the exit crash on any
        // system, seen most often on N64.
        if hadThread { _ = control.finished.wait(timeout: .now() + 8) }
        core.shutDownCore()
        DSCoreBridge.setCrashContext("")
        statusTimer?.invalidate(); statusTimer = nil
        let core = self.core
        Task { @MainActor in RetroAchievements.shared.stopGame(core: core) }
        audio.stop()
        thread = nil
    }

    private func applyRunState() {
        let halt = isPaused || appInactive
        control.setPaused(halt)
        core.setEmulationPaused(halt)
        if appInactive { presenter?.setActive(false) }
        else { presenter?.setActive(true) }
        if halt { audio.stop() }
        else if !appInactive { audio.start() }
    }

    private func suspendForBackground() {
        appInactive = true
        applyRunState()
        flushSave()
        autoSave()
    }

    private func resumeFromBackground() {
        guard appInactive else { return }
        appInactive = false
        applyRunState()
    }

    // MARK: Input (main thread)

    func setVirtual(_ button: DSButton, pressed: Bool) {
        if pressed { virtualButtons.insert(button) } else { virtualButtons.remove(button) }
        pushButtons()
    }

    /// Everything the on-screen controls hold right now (all fingers together).
    private var touchStick: (Float, Float) = (0, 0)
    func setStick(x: Float, y: Float) {
        touchStick = (x, y)
        pushAnalog()
    }

    func setTouchButtons(_ b: DSButton) {
        let before = hold
        let send = hold.touch(from: lastTouch, to: b)
        lastTouch = b
        if hold != before { holdState = hold }
        guard send != virtualButtons else { return }
        virtualButtons = send
        pushButtons()
    }

    // MARK: Hold Buttons (#12)

    private var lastTouch: DSButton = []
    private var hold = HoldButtons()
    /// Published copy for the overlay and the banner.
    @Published private(set) var holdState = HoldButtons()

    func beginHoldSelection() { hold.beginSelecting(); holdChanged() }
    func confirmHoldSelection() { hold.confirm(); holdChanged() }
    func cancelHoldSelection() { hold.cancel(); holdChanged() }
    func releaseHeldButtons() { hold.releaseAll(); holdChanged() }

    private func holdChanged() {
        holdState = hold
        virtualButtons = hold.selecting ? hold.held : hold.held.union(lastTouch)
        pushButtons()
    }

    func setDirections(_ dirs: DSButton) {
        virtualButtons.subtract([.up, .down, .left, .right])
        virtualButtons.formUnion(dirs)
        pushButtons()
    }

    func touch(down: Bool, x: Int, y: Int) { core.setTouch(down: down, x: x, y: y) }

    #if DEBUG
    private func debugPressA(remaining: Int) {
        guard remaining > 0, control.isRunning else { return }
        if isPaused {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.debugPressA(remaining: remaining)
            }
            return
        }
        // MK7 (and some other logos) want a touch on the bottom screen, not only A/Start.
        // Two of every three pulses are a centered bottom-screen tap (DS 256x192 → 320x240 in the core).
        // TPTestPressAOnly=YES: only press A (for menu Continue / dialogue), no Start or taps.
        if UserDefaults.standard.bool(forKey: "TPTestPressAOnly") {
            NSLog("TwinPlay TPTEST: press A only (%d left)", remaining)
            virtualButtons.insert(.a)
            pushButtons()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.40) { [weak self] in
                guard let self, self.control.isRunning else { return }
                self.virtualButtons.remove(.a)
                self.pushButtons()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
                    self?.debugPressA(remaining: remaining - 1)
                }
            }
            return
        }
        // Name entry: START moves the cursor to OK, then A confirms. No bottom-screen taps.
        if UserDefaults.standard.bool(forKey: "TPTestPressStartA") {
            let btn: DSButton = (remaining % 2 == 0) ? .start : .a
            NSLog("TwinPlay TPTEST: press %@ (%d left)", btn == .start ? "Start" : "A", remaining)
            virtualButtons.insert(btn)
            pushButtons()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.40) { [weak self] in
                guard let self, self.control.isRunning else { return }
                self.virtualButtons.remove(btn)
                self.pushButtons()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
                    self?.debugPressA(remaining: remaining - 1)
                }
            }
            return
        }
        let phase = remaining % 3
        if phase != 1 {
            NSLog("TwinPlay TPTEST: tap bottom screen (%d left)", remaining)
            self.touch(down: true, x: 128, y: 96)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.50) { [weak self] in
                guard let self, self.control.isRunning else { return }
                self.touch(down: false, x: 128, y: 96)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
                    self?.debugPressA(remaining: remaining - 1)
                }
            }
        } else {
            let btn: DSButton = (remaining % 6 == 1) ? .start : .a
            NSLog("TwinPlay TPTEST: press %@ (%d left)", btn == .start ? "Start" : "A", remaining)
            virtualButtons.insert(btn)
            pushButtons()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.40) { [weak self] in
                guard let self, self.control.isRunning else { return }
                self.virtualButtons.remove(btn)
                self.pushButtons()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
                    self?.debugPressA(remaining: remaining - 1)
                }
            }
        }
    }
    #endif

    private func pushButtons() {
        var mask = virtualButtons.union(controllers.pressed)
        if system == .n64 {
            let (x, y) = controllers.cStick
            if y > 0.40 { mask.insert(.cUp) }
            if y < -0.40 { mask.insert(.cDown) }
            if x < -0.40 { mask.insert(.cLeft) }
            if x > 0.40 { mask.insert(.cRight) }
        }
        core.setButtons(mask.rawValue)
        pushAnalog()
    }

    private func pushAnalog() {
        guard system == .n64 || system == .n3ds else { return }
        let useTouch = hypot(touchStick.0, touchStick.1) > 0.05
        let main = useTouch ? touchStick : controllers.analog
        core.setAnalog(x: main.0, y: main.1, stick: 0)
        if system == .n3ds { core.setAnalog(x: controllers.cStick.0, y: controllers.cStick.1, stick: 1) }
    }

    private var lastActions = Set<PadAction>()
    private var powerObserver: NSObjectProtocol?
    private var peekHeld = false
    private func controllerChanged() {
        pushButtons()
        let acts = controllers.actions
        let started = acts.subtracting(lastActions)
        lastActions = acts
        let hold = acts.contains(.fastForward)
        if hold != fastForwardHeld { fastForwardHeld = hold; applySpeed() }
        if started.contains(.quickSave) { saveState(slot: 1) }
        if started.contains(.quickLoad) { loadState(slot: 1) }
        if started.contains(.saveSlots) { showSlotsRequested = true }
        if started.contains(.pauseMenu) { showMenuRequested = true }
        if started.contains(.screenMode) { cycleScreenMode() }
        let peek = acts.contains(.peekScreen)
        if peek != peekHeld { peekHeld = peek; peekHidden = peek }
    }

    // MARK: Speed, rendering options

    private func applySpeed() {
        let on = fastForwardOn || fastForwardHeld
        let speed = on ? fastForwardSpeed : 1
        control.speed = speed
        audio.setFastForward(speed: speed, muteWhenFast: UserDefaults.standard.object(forKey: "ffMute") as? Bool ?? true)
    }

    /// User choice from Settings: saved, and cancels any automatic downgrade.
    func setRenderScale(_ n: Int) {
        noteManualVideo()
        UserDefaults.standard.set(n, forKey: "renderScale")
        scaleCeiling = nil
        slowTicks = 0
        applyRenderScale(n)
    }

    func setUseRecommended(_ on: Bool) {
        GameProfiles.setEnabled(profileID, on)
        useRecommended = on
        if on {
            let ident = GameProfiles.identify(url: romPath.map { URL(fileURLWithPath: $0) }, system: system, gameCode: core.gameCode)
            let rec = GameProfiles.recommend(ident, system: system)
            profileLocked = rec.locked
            didProbe3D = false
            scaleCeiling = rec.scale
            applyRenderScale(rec.scale)
            applyFilter(DisplayFilter(rawValue: rec.filter) ?? .nearest, persist: false)
            applyFrameSkip(FrameSkipSetting(rawValue: rec.frameSkip) ?? .off, persist: false)
        } else {
            scaleCeiling = nil
            let scale = UserDefaults.standard.object(forKey: "renderScale") as? Int ?? QualityDefaults.renderScale
            applyRenderScale(scale)
            applyFilter(DisplayFilter(rawValue: UserDefaults.standard.string(forKey: "displayFilter") ?? "") ?? .sharpBilinear, persist: false)
            applyFrameSkip(FrameSkipSetting(rawValue: UserDefaults.standard.string(forKey: "frameSkip") ?? "") ?? .auto, persist: false)
        }
    }

    private func noteManualVideo() {
        guard useRecommended else { return }
        GameProfiles.setEnabled(profileID, false)
        useRecommended = false
        scaleCeiling = nil
    }

    private func applyFilter(_ f: DisplayFilter, persist: Bool) {
        if persist { UserDefaults.standard.set(f.rawValue, forKey: "displayFilter") }
        appliedFilterRaw = f.rawValue
        presenter?.filter = f
    }

    private func applyFrameSkip(_ setting: FrameSkipSetting, persist: Bool) {
        if persist { UserDefaults.standard.set(setting.rawValue, forKey: "frameSkip") }
        appliedFrameSkipRaw = setting.rawValue
        control.frameSkipSetting = setting
    }

    /// Applies a scale for this session only (not saved).
    private func applyRenderScale(_ n: Int) {
        activeRenderScale = n
        DSCoreBridge.setCrashContext("game \(core.gameCode) system \(system) scale \(n)")
        // Runs on the emulation thread between runFrame calls; the core additionally latches the
        // value and applies it at the start of the next frame (never mid-frame).
        control.enqueue { [core] in core.renderScale = n }
    }

    /// 3D resolution actually in use (may be below the saved setting after an automatic downgrade).
    @Published private(set) var activeRenderScale = 2
    private var slowTicks = 0
    private var lastStepDown: CFTimeInterval = 0

    private var fastTicks = 0
    /// Wait before trying a higher 3D resolution again. Doubles each time a step up has to be
    /// undone soon after (a busy city that does not fit at the higher scale), so the picture
    /// does not cycle through a slow patch every 15 s.
    private var upGap = AutoQuality.minGapUp
    private var lastStepWasUp = false

    /// Automatic quality (ticks every 0.5 s): step the 3D resolution down after ~1.5 s of frames over
    /// 15 ms (or auto frame skip / <58 fps), at most every 5 s; step back up (never above the saved
    /// setting) only after ~10 s with real headroom. Decision logic lives in `AutoQuality`.
    private func checkAutoQuality(msPerFrame: Double, frameSkip: Int) {
        guard UserDefaults.standard.bool(forKey: "autoQuality"), !isPaused, !fastForwardOn, !fastForwardHeld,
              msPerFrame > 0 else { slowTicks = 0; fastTicks = 0; return }
        let autoSkipping = control.frameSkipSetting == .auto && frameSkip > 0
        let saved = scaleCeiling ?? (UserDefaults.standard.object(forKey: "renderScale") as? Int ?? QualityDefaults.renderScale)
        let now = CACurrentMediaTime()
        let step = AutoQuality.decide(msPerFrame: msPerFrame, autoSkipping: autoSkipping, fps: emulatedFPS,
                                      frameSkip: frameSkip, active: activeRenderScale, saved: saved,
                                      slowTicks: &slowTicks, fastTicks: &fastTicks,
                                      sinceLastChange: now - lastStepDown, captureInUse: core.captureInUse,
                                      minGapUp: upGap)
        guard step != 0 else { return }
        upGap = AutoQuality.nextUpGap(current: upGap, step: step, lastStepWasUp: lastStepWasUp, sinceLastChange: now - lastStepDown)
        lastStepWasUp = step > 0
        lastStepDown = now
        applyRenderScale(activeRenderScale + step)
        if step < 0 { showToast(String(localized: "Auto quality: 3D resolution \(activeRenderScale)x")) }
    }

    /// Experimental 16:9 3D for this game (per game).
    @Published private(set) var widescreen = false
    /// Screen mode for this game (remembered per game) and the temporary swap to the hidden screen.
    @Published private(set) var screenMode: ScreenMode = .both
    @Published var peekHidden = false
    /// Set by the menu to open the screen-size editor once the menu closes.
    @Published var editSizeRequested = false

    func setScreenMode(_ m: ScreenMode) {
        UserDefaults.standard.set(m.rawValue, forKey: "screenMode.\(core.gameCode)")
        screenMode = m
        peekHidden = false
    }
    func cycleScreenMode() {
        guard !isGBA else { return }
        guard Store.allows(.screenLayouts) else { showToast("Screen mode needs TwinPlay Plus"); return }
        setScreenMode(screenMode.next)
        showToast(screenMode.label)
    }

    /// Pushes the 3D enhancement settings to the core (between frames).
    func applyEnhancements() {
        let d = UserDefaults.standard
        let aa = d.object(forKey: "antiAlias") as? Int ?? 1          // default: edge smoothing
        let tex = d.object(forKey: "textureFilter") as? Bool ?? false
        let wide = widescreen
        control.enqueue { [core] in core.setEnhancements(antiAlias: aa, textureFilter: tex, widescreen: wide) }
    }

    func setWidescreen(_ on: Bool) {
        guard !isTestMode else { return }
        UserDefaults.standard.set(on, forKey: "widescreen.\(core.gameCode)")
        widescreen = on
        applyEnhancements()
    }

    func setColor(_ c: ColorAdjust) {
        let d = UserDefaults.standard
        d.set(Double(c.brightness), forKey: "colorBrightness"); d.set(Double(c.contrast), forKey: "colorContrast")
        d.set(Double(c.saturation), forKey: "colorSaturation"); d.set(Double(c.gamma), forKey: "colorGamma")
        d.set(c.lcdCorrection, forKey: "lcdCorrection")
        presenter?.color = c
    }

    func setFrameBlend(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "frameBlend")
        presenter?.frameBlend = on
    }

    func setDisplayFilter(_ f: DisplayFilter) {
        noteManualVideo()
        applyFilter(f, persist: true)
    }

    var cheatKey: String { CheatStore.key(system: system, gameCode: core.gameCode, title: core.romTitle) }

    func setCheats(_ list: [CheatEntry]) {
        cheats = list
        CheatStore.save(list, key: cheatKey)
        applyCheats()
    }
    private func applyCheats() {
        // RetroAchievements hardcore: no cheats.
        let allowed = RetroAchievementsRules.allowsCheats(hardcore: RetroAchievementsRules.hardcore)
        let codes = allowed ? cheats.filter(\.enabled).map(\.code) : [], sys = CheatStore.coreSystem(system)
        control.enqueue { [core] in core.setCheats(codes, system: sys) }
    }

    /// Store a packed 3DS still captured from the working CAMetalLayer.
    /// Safe to call from the display-link tick on the main thread.
    func noteN3DSPackedScreenshot(_ image: UIImage) {
        guard PlaySnapshotQuality.isUsable(image) else { return }
        n3dsShotLock.lock()
        n3dsPackedShot = image
        n3dsShotLock.unlock()
    }

    /// Last usable packed 3DS still, if any. Safe from the emulation thread.
    func n3dsPackedScreenshot() -> UIImage? {
        n3dsShotLock.lock()
        let img = n3dsPackedShot
        n3dsShotLock.unlock()
        return img
    }

    /// Both DS screens stacked (or the single GBA/GB screen), scaled up 3x with sharp pixels.
    /// 3DS uses the Metal swapchain still: Vulkan never writes the software FB.
    func screenshotImage() -> UIImage? {
        if system == .n3ds, let packed = n3dsPackedScreenshot() { return packed }
        guard let cg = core.copyThumbnailImage() else { return nil }
        let size = CGSize(width: cg.width * 3, height: cg.height * 3)
        let f = UIGraphicsImageRendererFormat(); f.scale = 1
        let img = UIGraphicsImageRenderer(size: size, format: f).image { ctx in
            ctx.cgContext.interpolationQuality = .none
            UIImage(cgImage: cg).draw(in: CGRect(origin: .zero, size: size))
        }
        return PlaySnapshotQuality.isUsable(img) ? img : nil
    }

    func showToast(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if self?.toast == text { self?.toast = nil }
        }
    }

    // MARK: Commands (run between frames on the emulation thread)

    func reset() { control.enqueue { [core] in core.reset(); RAClient.shared.gameReset() } }

    // MARK: Cartridge save chip

    var saveTypeOverride: Int { isTestMode ? 0 : UserDefaults.standard.integer(forKey: "saveType.\(core.gameCode)") }

    /// Description of the save chip plus a note if an old, mismatched save file was set aside.
    func saveInfo(_ done: @escaping (String) -> Void) {
        control.enqueue { [core] in
            var text = String(localized: "Save chip: \(core.saveTypeDescription)")
            if core.loadedSaveRejected { text += ". " + String(localized: "The old save file did not match this game and was kept as a .bak backup.") }
            DispatchQueue.main.async { done(text) }
        }
    }

    /// Changes the save chip for this game and restarts it (the current save data is kept).
    func setSaveTypeOverride(_ n: Int) {
        guard !isTestMode else { return }
        UserDefaults.standard.set(n, forKey: "saveType.\(core.gameCode)")
        control.enqueue { [core] in core.flushSave(); core.saveTypeOverride = n; core.reset() }
        showToast("Save chip changed. The game restarted.")
    }

    /// Moves the save file aside (".sav.bak") and restarts the game with blank save memory.
    func deleteSaveData() {
        guard !isTestMode else { return }
        control.enqueue { [core] in core.deleteSaveData(); core.reset() }
        showToast("Save data deleted (backup kept). The game restarted.")
    }

    /// Toast when iOS is likely limiting performance (Low Power Mode, or the phone is hot).
    func warnIfThrottled() {
        let p = ProcessInfo.processInfo
        if p.isLowPowerModeEnabled {
            showToast("Low Power Mode is on: iOS may limit games to 30 fps")
        } else if p.thermalState == .serious || p.thermalState == .critical {
            showToast("iPhone is hot: iOS is slowing it down")
        }
    }

    func setFrameSkip(_ setting: FrameSkipSetting) {
        noteManualVideo()
        applyFrameSkip(setting, persist: true)
    }

    /// Saves to a slot (with a thumbnail of both screens). Runs between frames.
    func saveState(slot: Int, completion: ((Bool) -> Void)? = nil) {
        guard !isTestMode else { completion?(false); return }
        control.enqueue { [core, slots, weak self] in
            var ok = false
            if let data = core.saveState() {
                var png: Data?
                if self?.system == .n3ds, let shot = self?.n3dsPackedScreenshot(),
                   let data = shot.pngData() {
                    png = data
                } else if let cg = core.copyThumbnailImage(), PlaySnapshotQuality.isUsable(cg) {
                    png = UIImage(cgImage: cg).pngData()
                }
                ok = slots.write(slot: slot, state: data, thumbnail: png)
            }
            DispatchQueue.main.async {
                if ok { Task { @MainActor in CloudSaveSync.shared.savedLocally() } }   // #19 upload to iCloud
                if slot != SaveSlotStore.autoSlot {
                    self?.showToast(ok ? (slot == 0 ? String(localized: "Saved to auto slot") : String(localized: "Saved to slot \(slot)")) : String(localized: "Could not save the state"))
                }
                completion?(ok)
            }
        }
    }

    func loadState(slot: Int, completion: ((Bool) -> Void)? = nil) {
        // RetroAchievements hardcore: loading states is not allowed (saving still is).
        guard RetroAchievementsRules.allowsLoadingStates(hardcore: RetroAchievementsRules.hardcore) else {
            showToast("Hardcore mode: loading states is off"); completion?(false); return
        }
        control.enqueue { [core, slots, weak self] in
            var ok = false
            if let data = slots.read(slot: slot) { ok = core.loadState(data) }
            if ok { RAClient.shared.stateLoaded() }
            DispatchQueue.main.async {
                self?.showToast(ok ? (slot == 0 ? String(localized: "Loaded auto slot") : String(localized: "Loaded slot \(slot)")) : String(localized: "No compatible state in this slot"))
                completion?(ok)
            }
        }
    }

    /// Writes the automatic slot (when leaving the game or going to the background).
    func autoSave() { saveState(slot: SaveSlotStore.autoSlot) }

    // MARK: Loop

    /// Emulation loop, woken by the display (vsync signals from the presenter) but paced by
    /// wall time at the DS rate (59.8261 Hz; never faster). Falls back to a timer when no
    /// display link is running. Frame skip only drops pictures; emulation always runs at speed.
    private static func loop(core: DSCoreBridge, control: LoopControl, rate: Double) {
        let frameDuration = 1.0 / rate                          // DS 59.8261 Hz, GBA/GB 59.7275 Hz
        core.renderThreads = control.renderThreads
        var pacer = FramePacer(frameDuration: frameDuration)
        var last = CACurrentMediaTime()
        var emaMs = 0.0, emaDrawnMs = 0.0
        var skip = 0
        let ra = RAClient.shared
        var idleTicks = 0
        while control.isRunning {
            control.drainCommands()
            if control.isPaused {
                Thread.sleep(forTimeInterval: 0.03)
                idleTicks += 1
                if idleTicks % 33 == 0 { ra.idle() }           // about once a second
                while control.vsync.wait(timeout: .now()) == .success {}   // drop vsyncs queued while paused
                last = CACurrentMediaTime(); pacer.reset()
                continue
            }
            let woke = control.vsync.wait(timeout: .now() + frameDuration) == .success   // vsync, or timer fallback
            let now = CACurrentMediaTime()
            let speed = control.speed
            pacer.advance(dt: now - last, woke: woke, speed: speed)
            last = now
            // No audio nudging here: emulation runs at the DS rate of wall time, so game speed
            // and music tempo never change. AudioOutput absorbs clock drift by resampling.

            var ran = 0
            let maxRun = speed == 0 ? Int.max : 3 * max(speed, 1)
            let deadline = now + frameDuration * 0.9            // unlimited: run until the next vsync
            while ran < maxRun && (speed == 0 ? CACurrentMediaTime() < deadline : pacer.credit >= 1) {
                // While fast-forwarding only about 60 pictures per second can be shown anyway.
                let ffSkip = speed == 0 ? 5 : max(speed, 1) - 1
                let wanted = max(control.frameSkip(auto: skip), ffSkip)
                if core.frameSkip != wanted { core.frameSkip = wanted }
                let t0 = CACurrentMediaTime()
                let seq0 = core.frameSequence
                core.runFrame()
                let ms = (CACurrentMediaTime() - t0) * 1000
                ra.doFrame()                                   // RetroAchievements (no-op without a game)
                emaMs = emaMs == 0 ? ms : emaMs * 0.95 + ms * 0.05
                // Track the cost of fully drawn frames even while skipping. Before, it was only
                // updated with skip off, so once auto skip engaged it never measured a cheap frame
                // again and stayed at 30 fps for the rest of the session.
                if core.frameSequence != seq0 { emaDrawnMs = emaDrawnMs == 0 ? ms : emaDrawnMs * 0.95 + ms * 0.05 }
                pacer.credit -= 1; ran += 1
            }
            if speed == 0 { pacer.credit = 0 }
            // Auto frame skip: skip pictures while the average frame costs too much; return to
            // full rendering once a fully drawn frame fits comfortably in the 16.7 ms budget.
            if speed != 1 { control.report(msPerFrame: emaMs, frameSkip: core.frameSkip); continue }
            if emaMs > 15.5 { skip = min(skip + 1, 2); emaMs = 12 }
            else if skip > 0 && emaDrawnMs > 0 && emaDrawnMs < 13.5 { skip -= 1; emaMs = 12 }
            control.report(msPerFrame: emaMs, frameSkip: core.frameSkip)
        }
        control.drainCommands()     // run any pending flush
        core.flushSave()
        control.finished.signal()
    }
}

/// How many emulated frames are owed (pure, unit-tested). On a 60 Hz display (incl. ProMotion
/// pinned to 60) it runs exactly one DS frame per refresh: 0.29 % faster than 59.8261 Hz
/// (inaudible; AudioOutput's drift correction absorbs it) and no duplicated picture every
/// ~5.7 s. Refreshes the emulation thread did not see (the display link runs on the main thread,
/// so a busy main thread delays or merges them) are counted from the elapsed time and made up;
/// before, a locked loop added one frame per wake whatever the gap, so every main-thread hitch
/// permanently lost frames and games ran below 60 fps (Pokémon's busy menus / battles).
/// Otherwise frames are owed by wall time at the DS rate.
struct FramePacer {
    let frameDuration: Double
    var credit = 0.0
    /// Measured display refresh interval (0 = unknown).
    var vsyncEma = 0.0
    static let refresh60 = 1.0 / 60.0

    mutating func reset() { credit = 0; vsyncEma = 0 }

    var isLocked: Bool { abs(vsyncEma - Self.refresh60) < 0.0015 }

    mutating func advance(dt: Double, woke: Bool, speed: Int) {
        // Only clean single-refresh gaps feed the refresh estimate (not queued wakes or hitches).
        if woke && dt > 0.008 && dt < 0.025 { vsyncEma = vsyncEma == 0 ? dt : vsyncEma * 0.9 + dt * 0.1 }
        if woke && speed == 1 && isLocked {
            // Wall time in 60 Hz refreshes, snapped to whole refreshes when it is close to one so
            // display jitter never yields 0 frames on one refresh and 2 on the next (a repeated
            // picture). Merged refreshes (a long gap) and queued wakes (a short one) still add up
            // to the true elapsed time, so nothing is lost or run twice.
            let r = dt / Self.refresh60, n = r.rounded()
            credit = max(credit, 0) + (abs(r - n) < 0.25 ? n : r)
        } else {
            credit += dt / frameDuration * Double(max(speed, 1))
        }
        credit = min(credit, 4 * Double(max(speed, 1)))     // after a stall, do not try to catch up forever
    }
}

enum FrameSkipSetting: String, CaseIterable, Identifiable {
    case auto, off, one, two
    var id: String { rawValue }
    var label: String { englishLabel.loc }
    /// English source text (the String Catalog key).
    var englishLabel: String {
        switch self {
        case .auto: return "Auto"
        case .off: return "Off"
        case .one: return "1 (30 fps)"
        case .two: return "2 (20 fps)"
        }
    }
}

/// Small lock-protected state shared between the UI and the emulation thread.
final class LoopControl {
    private let lock = NSLock()
    private var running = false
    private var paused = false
    private var commands: [() -> Void] = []
    private var skipSetting: FrameSkipSetting = .auto
    private var lastMs = 0.0, lastSkip = 0
    private var speedValue = 1
    /// Emulation speed multiplier (1 = normal, 2, 3; 0 = unlimited).
    var speed: Int {
        get { lock.lock(); defer { lock.unlock() }; return speedValue }
        set { lock.lock(); speedValue = newValue; lock.unlock() }
    }
    /// Signalled by the display link once per refresh.
    let vsync = DispatchSemaphore(value: 0)
    /// Signalled when the emulation loop exits.
    let finished = DispatchSemaphore(value: 0)
    var renderThreads = 0

    var frameSkipSetting: FrameSkipSetting {
        get { lock.lock(); defer { lock.unlock() }; return skipSetting }
        set { lock.lock(); skipSetting = newValue; lock.unlock() }
    }
    /// Frame skip to use now, given the automatic choice.
    func frameSkip(auto: Int) -> Int {
        switch frameSkipSetting {
        case .auto: return auto
        case .off: return 0
        case .one: return 1
        case .two: return 2
        }
    }
    func report(msPerFrame: Double, frameSkip: Int) { lock.lock(); lastMs = msPerFrame; lastSkip = frameSkip; lock.unlock() }
    func performanceSnapshot() -> (msPerFrame: Double, frameSkip: Int) {
        lock.lock(); defer { lock.unlock() }; return (lastMs, lastSkip)
    }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    var isPaused: Bool { lock.lock(); defer { lock.unlock() }; return paused }
    func setRunning(_ v: Bool) { lock.lock(); running = v; lock.unlock() }
    func setPaused(_ v: Bool) { lock.lock(); paused = v; lock.unlock() }
    func enqueue(_ c: @escaping () -> Void) { lock.lock(); commands.append(c); lock.unlock() }
    func drainCommands() {
        lock.lock(); let pending = commands; commands.removeAll(); lock.unlock()
        pending.forEach { $0() }
    }
}


/// Pure decision for automatic 3D quality (unit-tested). Returns -1 (step down), +1 (step up) or 0.
enum AutoQuality {
    static let downTicks = 3, upTicks = 20
    static let slowMs = 15.0, headroomMs = 9.0
    static let minGapDown: Double = 5, minGapUp: Double = 15

    static func decide(msPerFrame: Double, autoSkipping: Bool, fps: Double, frameSkip: Int, active: Int, saved: Int,
                       slowTicks: inout Int, fastTicks: inout Int, sinceLastChange: Double, captureInUse: Bool,
                       minGapUp: Double = AutoQuality.minGapUp) -> Int {
        let lowFPS = fps > 0 && fps < 58 && frameSkip == 0
        let slow = msPerFrame > slowMs || autoSkipping || lowFPS
        let roomy = msPerFrame < headroomMs && !autoSkipping && frameSkip == 0 && (fps == 0 || fps >= 59)
        slowTicks = slow ? slowTicks + 1 : 0
        fastTicks = roomy ? fastTicks + 1 : 0
        // Never change during capture-based transitions (race results, screen fades).
        guard !captureInUse else { return 0 }
        if slowTicks >= downTicks, active > 1, sinceLastChange > minGapDown { slowTicks = 0; fastTicks = 0; return -1 }
        if fastTicks >= upTicks, active < saved, sinceLastChange > minGapUp { slowTicks = 0; fastTicks = 0; return 1 }
        return 0
    }

    /// Back-off for stepping up: a step down within 30 s of a step up doubles the wait (up to
    /// 4 minutes); a step down after a long stable stretch resets it.
    static func nextUpGap(current: Double, step: Int, lastStepWasUp: Bool, sinceLastChange: Double) -> Double {
        guard step < 0 else { return current }
        if lastStepWasUp && sinceLastChange < 30 { return min(current * 2, 240) }
        return sinceLastChange > 300 ? minGapUp : current
    }
}
