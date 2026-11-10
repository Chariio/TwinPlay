// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import PhotosUI
import SafariServices
import StoreKit
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var library: ROMLibrary
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.requestReview) private var requestReview
    @State private var importer: ImporterMode?
    @State private var showFolderPrompt = false
    @State private var session: EmulatorSession?
    /// Running time for the game on screen. The review prompt reads it only after the cover closes.
    @State private var reviewClock = ReviewPlayClock()
    @State private var openingFromCloud = false     // #19 waiting for iCloud before starting a game
    @State private var loadError: String?
    @AppStorage("librarySort") private var sortRaw = ROMLibrary.SortOrder.name.rawValue
    @State private var search = ""
    @State private var renaming: ROMLibrary.Entry?
    @State private var renameText = ""
    @State private var coverTarget: ROMLibrary.Entry?
    @State private var photoTarget: ROMLibrary.Entry?
    @State private var browserURL: IdentifiedURL?
    @State private var deleting: ROMLibrary.Entry?
    @State private var showSettings = false
    @State private var showBackground = false
    @State private var showAbout = false
    @State private var privacyChoicesRequired = false
    @State private var showIcons = false
    @State private var showPaywallSheet = false
    @State private var showSystem = false
    @State private var showSkins = false
    @State private var showReport = false
    /// DEBUG screenshot aid only (-TwinPlayShowRetroAchievements YES); never set in Release.
    @State private var debugShowRA = false
    /// Controller navigation: focused game (index into navList) and the controller action sheet.
    @State private var padFocus = 0
    @State private var padMenuEntry: ROMLibrary.Entry?
    @State private var gridWidth: CGFloat = 390
    @State private var hintsVisible = true
    @State private var hintsToken = 0
    @State private var viewportHeight: CGFloat = 0     // visible height of the library scroll view
    /// Phone in landscape: wide and short, so the cover-flow stage must fit the visible height.
    private var shortLandscape: Bool { viewportHeight > 0 && viewportHeight < 600 && gridWidth > viewportHeight * 1.2 }
    @ObservedObject private var pad = PadNavigator.shared
    @AppStorage("libraryBackground") private var backgroundID = "bedroom"
    @State private var boxArtTarget: ROMLibrary.Entry?
    @State private var titleTarget: ROMLibrary.Entry?
    @ObservedObject private var titleGen = TitleScreenGenerator.shared
    @State private var findingAll = false
    @State private var findAllProgress = ""
    /// Library filter: "all", "ds" or "gba".
    @AppStorage("librarySystem") private var systemFilter = "all"
    /// Global tile style (each game can override it).
    @AppStorage("tileStyle") private var tileStyleRaw = TileStyle.boxArt.rawValue
    /// "coverflow" (default) or "grid".
    @AppStorage("libraryLayout") private var layoutRaw = "coverflow"
    @ObservedObject private var store = Store.shared
    /// Library style: "classicDS" (default, two-screen Classic DS Menu) or "standard". Free.
    @AppStorage("libraryStyle") private var libraryStyle = "classicDS"
    @AppStorage("classicFolder") private var classicFolderRaw = ClassicDSMenuView.Folder.all.rawValue
    @State private var classicFocus = 0
    @State private var posture: FoldPosture = .flat
    @State private var hingeAngle: Double?
    @State private var playStart: (url: URL, date: Date)?
    @State private var infoEntry: ROMLibrary.Entry?
    @State private var showMenuColors = false
    @State private var showOnboarding = false
    private var isClassic: Bool { libraryStyle == "classicDS" }
    private var classicFolder: Binding<ClassicDSMenuView.Folder> {
        Binding(get: { ClassicDSMenuView.Folder(rawValue: classicFolderRaw) ?? .all }, set: { classicFolderRaw = $0.rawValue })
    }
    private var classicEntries: [ROMLibrary.Entry] {
        let all = GameSystem.allCases.flatMap { library.sorted(sort, search: "", system: $0) }
        return (ClassicDSMenuView.Folder(rawValue: classicFolderRaw) ?? .all).filter(all)
    }

    private var effectivePosture: FoldPosture {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "TwinPlayFoldPosture") {
        case "book": return .book
        case "open": return .open
        case "closed": return .closed
        default: break
        }
        #endif
        return posture
    }

    enum ImporterMode: Identifiable { case games, cover, folder; var id: Int { self == .games ? 0 : self == .cover ? 1 : 2 } }

    private var sort: ROMLibrary.SortOrder { ROMLibrary.SortOrder(rawValue: sortRaw) ?? .name }
    /// Cover Flow and the cartridge / title-screen tile styles are Pro; Free and Plus use the box-art grid.
    private var tileStyle: TileStyle { Store.allows(.coverFlow) ? (TileStyle(rawValue: tileStyleRaw) ?? .boxArt) : .boxArt }
    private var isCoverFlow: Bool { layoutRaw == "coverflow" && Store.allows(.coverFlow) }
    private func toggleLayout() {
        if isCoverFlow { layoutRaw = "grid" } else if Store.gate(.coverFlow) { layoutRaw = "coverflow" }
    }
    private func openBoxArt(_ e: ROMLibrary.Entry) { if BoxArtFinder.isEnabled { boxArtTarget = e } }
    private func openTitleFinder(_ e: ROMLibrary.Entry) { if BoxArtFinder.isEnabled { titleTarget = e } }
    /// True when any game is drawn with the Title screen style (then thumbnails are captured).
    private var usesTitleScreens: Bool {
        Store.allows(.coverFlow) && (tileStyle == .titleScreen || library.entries.contains { $0.styleOverride == .titleScreen })
    }
    private func ensureTitleScreens() {
        guard usesTitleScreens else { return }
        let targets = tileStyle == .titleScreen ? library.entries : library.entries.filter { $0.styleOverride == .titleScreen }
        titleGen.ensure(targets, library: library)
    }
    /// After the menu chooser (if any) and the StoreKit entitlement pass. Pro never starts the SDK.
    private func startAdsIfReady() {
        guard !showOnboarding, store.entitlementsReady else { return }
        #if DEBUG
        let autoOpen = UserDefaults.standard.string(forKey: "TwinPlayAutoOpen") != nil
        #else
        let autoOpen = false
        #endif
        if MenuOnboarding.shouldPresent() && !autoOpen { return }
        AdConfig.start()
    }

    /// Asks for a games folder once. The prompted flag is set here so a later call does not ask again.
    private func presentFolderPromptIfNeeded() async {
        guard !UserDefaults.standard.bool(forKey: ROMFolder.promptedKey), !ROMFolder.hasFolder else { return }
        UserDefaults.standard.set(true, forKey: ROMFolder.promptedKey)
        #if DEBUG
        let skipPrompt = UserDefaults.standard.bool(forKey: "NDUOSkipFolderPrompt")
        #else
        let skipPrompt = false
        #endif
        if !skipPrompt {
            try? await Task.sleep(nanoseconds: 700_000_000)
            showFolderPrompt = true
        }
    }
    /// #3b: on the iPhone Duo every screen covers the whole display (see DuoFullScreen).
    private var isDuoWindow: Bool { OuterDisplay.duoWindow(hingeKnown: hingeAngle != nil, posture: effectivePosture) }
    private var filterSystem: GameSystem? { GameSystem(rawValue: systemFilter) }
    private let columns = [GridItem(.adaptive(minimum: 128, maximum: 180), spacing: 16)]

    var body: some View {
        Group {
            if isClassic { classicBody } else { standardBody }
        }
        .duoFullScreen(isDuoWindow)
        .observeHingePosture($posture, angle: $hingeAngle)
        .debugForceLandscape()
        .overlay { if isClassic { libraryDialog } }
        .fileImporter(isPresented: Binding(get: { importer != nil }, set: { if !$0 { importer = nil } }),
                      allowedContentTypes: importer == .cover ? [.image] : importer == .folder ? [.folder] : [ROMLibrary.ndsType, ROMLibrary.gbaType, ROMLibrary.gbType, ROMLibrary.gbcType, ROMLibrary.nesType, ROMLibrary.snesType, ROMLibrary.n64Type, ROMLibrary.n3dsType, .data],
                      allowsMultipleSelection: importer == .games) { result in
            if importer == .folder {
                importer = nil
                if case .success(let urls) = result, let folder = urls.first { chooseFolder(folder) }
                else if case .failure(let error) = result { library.lastError = error.localizedDescription }
                return
            }
            let target = coverTarget
            coverTarget = nil
            importer = nil
            switch result {
            case .success(let urls):
                if let target { if let u = urls.first { setCover(fromFile: u, for: target) } }
                else { library.importFiles(urls) }
            case .failure(let error): library.lastError = error.localizedDescription
            }
        }
        .sheet(item: $photoTarget) { entry in
            PhotoPicker { image in
                photoTarget = nil
                if let image { library.setCover(image, for: entry) }
            }
        }
        .sheet(item: $browserURL) { item in
            SafariView(url: item.url).ignoresSafeArea()
        }
        .sheet(item: $boxArtTarget) { entry in
            BoxArtPickerView(entry: entry,
                             onGoogle: { if let u = ROMLibrary.coverSearchURL(for: entry) { browserURL = IdentifiedURL(url: u) } },
                             onPhotos: { photoTarget = entry })
                .environmentObject(library)
                .padScope("boxart") { if $0 == .b { boxArtTarget = nil } }
                .duoFullScreen(isDuoWindow)
        }
        .sheet(item: $padMenuEntry) { entry in
            let live = library.entries.first { $0.id == entry.id } ?? entry
            PadActionsSheet(entry: live, actions: padActions(for: live)) { padMenuEntry = nil }
                .environmentObject(library)
                .duoFullScreen(isDuoWindow)
        }
        .sheet(isPresented: $showSettings) { ControllerSettingsView().duoFullScreen(isDuoWindow) }
        .sheet(isPresented: $showBackground) { LibraryBackgroundSettings().duoFullScreen(isDuoWindow) }
        .sheet(isPresented: $showAbout) { AboutView().duoFullScreen(isDuoWindow) }
        .onAppear { privacyChoicesRequired = Consent.privacyOptionsRequired }
        .onReceive(NotificationCenter.default.publisher(for: Consent.updatedNote)) { _ in privacyChoicesRequired = Consent.privacyOptionsRequired }
        .sheet(isPresented: $showReport) {
            ReportGameView(games: library.entries.map { .init(title: $0.name, id: $0.gameCode ?? "", system: $0.system.longName) })
                .duoFullScreen(isDuoWindow)
        }
        .sheet(isPresented: $showIcons) { AppIconPickerView().duoFullScreen(isDuoWindow) }
        .sheet(isPresented: $showSystem) { SystemSettingsView().environmentObject(library).duoFullScreen(isDuoWindow) }
        .sheet(isPresented: $showSkins) { SkinPickerView().duoFullScreen(isDuoWindow) }
        .sheet(isPresented: $debugShowRA) { NavigationStack { RetroAchievementsView() }.duoFullScreen(isDuoWindow) }
        .sheet(isPresented: $showPaywallSheet) { PaywallView().duoFullScreen(isDuoWindow) }
        .sheet(item: $titleTarget) { entry in
            BoxArtPickerView(entry: entry, kind: .title,
                             onGoogle: { if let u = ROMLibrary.coverSearchURL(for: entry) { browserURL = IdentifiedURL(url: u) } },
                             onPhotos: { photoTarget = entry })
                .environmentObject(library)
                .padScope("titlefinder") { if $0 == .b { titleTarget = nil } }
        }
        .alert("Find your games", isPresented: $showFolderPrompt) {
            Button("Choose Folder…") { coverTarget = nil; importer = .folder }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("Pick the folder where you keep your .nds, .gba, .gb, .gbc, .nes, .sfc, .smc, .n64, .z64, .v64, .3ds, .cci and .cxi files, for example On My iPhone › Downloads. TwinPlay imports every game in it and its subfolders and skips ones you already have. Use “Find new games” later to pick up new ones.")
        }
        .task {
            let autoOpening = UserDefaults.standard.string(forKey: "TwinPlayAutoOpen") != nil
            let presentMenu = MenuOnboarding.shouldPresent() && !autoOpening
            if presentMenu {
                showOnboarding = true
            } else if UserDefaults.standard.object(forKey: MenuOnboarding.styleKey) != nil {
                UserDefaults.standard.set(true, forKey: MenuOnboarding.chosenKey)
            }
            // Games folder: first-run prompt (rescans are manual only). Held until the style choice closes.
            if !presentMenu { await presentFolderPromptIfNeeded() }
            #if DEBUG
            // Testing aid (simulator screenshots): -TwinPlayImportDir /folder copies any games there that
            // are not in the library yet; -TwinPlayAutoOpen /path/to/game.nds starts one.
            if let dir = UserDefaults.standard.string(forKey: "TwinPlayImportDir") {
                let have = Set(library.entries.map(\.url.lastPathComponent))
                let files = ((try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)) ?? [])
                    .filter { ROMLibrary.romExtensions.contains($0.pathExtension.lowercased()) && !have.contains($0.lastPathComponent) }
                if !files.isEmpty { library.importFiles(files) }
            }
            if session == nil, let p = UserDefaults.standard.string(forKey: "TPAutoBoot") ?? UserDefaults.standard.string(forKey: "TwinPlayAutoOpen") {
                // A relative path is taken inside Documents (on a device the container path is not known up front).
                // -TwinPlayAutoOpenDelay <seconds> waits first (opens from a library that has settled).
                let wait = UserDefaults.standard.double(forKey: "TwinPlayAutoOpenDelay")
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                open(rom: p.hasPrefix("/") ? URL(fileURLWithPath: p) : docs.appendingPathComponent(p))
            }
            if UserDefaults.standard.bool(forKey: "TwinPlayShowIcons") { showIcons = true }
            if UserDefaults.standard.bool(forKey: "TwinPlayShowSkins") { try? await Task.sleep(nanoseconds: 1_000_000_000); showSkins = true }
            // -TwinPlayShowRetroAchievements YES: Settings > RetroAchievements (signed out; never signs in).
            if UserDefaults.standard.bool(forKey: "TwinPlayShowRetroAchievements") { try? await Task.sleep(nanoseconds: 1_500_000_000); debugShowRA = true }
            if UserDefaults.standard.bool(forKey: "TwinPlayShowSystem") { try? await Task.sleep(nanoseconds: 1_500_000_000); showSystem = true }
            if UserDefaults.standard.bool(forKey: "TwinPlayOpenSettings") { try? await Task.sleep(nanoseconds: 1_500_000_000); showSettings = true }
            if UserDefaults.standard.string(forKey: "TwinPlayShowPaywall") == "sheet" { showPaywallSheet = true }
            else if UserDefaults.standard.bool(forKey: "TwinPlayShowPaywall") { try? await Task.sleep(nanoseconds: 800_000_000); PaywallPresenter.present() }
            if let f = UserDefaults.standard.string(forKey: "TwinPlayClassicFocus").flatMap(Int.init) { classicFocus = f }
            if let d = UserDefaults.standard.string(forKey: "TwinPlayWidgetPreviews") { await WidgetPreviewDump.run(to: URL(fileURLWithPath: d)) }
            #endif
        }
        .onAppear {
            ensureTitleScreens()
            if session == nil { MenuMusic.shared.startIfAllowed() }
            startAdsIfReady()
        }
        .onChange(of: store.entitlementsReady) { _ in startAdsIfReady() }
        .onChange(of: store.purchasedTier) { _ in startAdsIfReady() }
        .onChange(of: tileStyleRaw) { _ in ensureTitleScreens() }
        .onChange(of: library.entries.count) { _ in ensureTitleScreens() }
        .onChange(of: session == nil) { idle in
            titleGen.paused = !idle
            if idle { MenuMusic.shared.startIfAllowed() } else { MenuMusic.shared.stopForGameplay() }
            if idle {
                CloudSaveSync.shared.setPlaying(saveFile: nil)   // #19: upload this game's save / states
                ensureTitleScreens()
                if let p = playStart { library.addPlayTime(p.url, seconds: Date().timeIntervalSince(p.date)); playStart = nil }
                // Back in the library, never over the game. Wait out the cover dismiss so
                // StoreKit does not drop the request, and skip it if a game is open again.
                let played = reviewClock.finish()
                if ReviewPrompt.noteSession(seconds: played) {
                    ReviewPrompt.scheduleAsk(stillInLibrary: { session == nil }, request: { requestReview() })
                }
            }
        }
        .fullScreenCover(item: $session) { session in
            EmulatorView(session: session, reviewClock: reviewClock) {
                if let url = session.romURL, let snap = session.screenshotImage() {
                    library.savePlaySnapshot(snap, for: url)
                }
                self.session = nil
            }
        }
        // Widget taps: nduo://open?id=<file> starts that game, nduo://library just shows the library.
        // While a game is running the app comes back to it unchanged (never swaps games under the player).
        .onOpenURL { url in
            guard session == nil, let id = WidgetShared.gameID(from: url) else { return }
            if let e = library.entries.first(where: { $0.url.lastPathComponent == id }) { open(rom: e.url) }
            else { library.lastError = String(localized: "That game is no longer in your library.") }
        }
        .sheet(item: $infoEntry) { GameInfoSheet(entry: $0).environmentObject(library) }
        .menuColorsPopover(isPresented: $showMenuColors)
        .fullScreenCover(isPresented: $showOnboarding) {
            MenuOnboardingView { style in
                MenuOnboarding.choose(style)
                libraryStyle = style
                showOnboarding = false
            }
            .interactiveDismissDisabled(true)
        }
        .onChange(of: showOnboarding) { showing in
            if !showing {
                startAdsIfReady()
                Task { await presentFolderPromptIfNeeded() }
            }
        }
    }

    /// Classic DS Menu library style (two screens split at the hinge on an open iPhone Duo).
    private var classicBody: some View {
        ClassicDSMenuView(entries: classicEntries, folder: classicFolder, focus: $classicFocus, posture: effectivePosture,
                          hingeKnown: hingeAngle != nil,
                          onPlay: { open(rom: $0.url) },
                          onFavorite: { library.toggleFavorite($0) },
                          onOptions: { padMenuEntry = $0 },
                          menu: AnyView(HStack(spacing: 6) {
                              Menu {
                                  importMenuItems
                                  if let url = ROMFolder.resolve() {
                                      Button { library.importFolder(url) } label: { Label("Find New Games Now", systemImage: "arrow.clockwise") }
                                  }
                              } label: {
                                  AddGamesLabel()
                              }.accessibilityLabel("Add games")
                              Menu { libraryMenuItems } label: {
                                  Image(systemName: "line.3.horizontal").font(.system(size: 14, weight: .bold)).foregroundStyle(ClassicPalette.text)
                                      .frame(width: 34, height: 28)
                                      .glassSurface(Capsule(), interactive: true)
                              }.accessibilityLabel("Library menu")
                          }),
                          onMenu: { showSettings = true },
                          controllerEnabled: session == nil && padMenuEntry == nil && renaming == nil && deleting == nil)
    }

    /// The library's main menu (top-left in Standard, the ⋯ button in Classic), in sections:
    /// Games, Look, Settings & About, and the testing tools tucked into a submenu at the end.
    @ViewBuilder private var libraryMenuItems: some View {
        Section("Games") {
            importMenuItems
            if let url = ROMFolder.resolve() {
                Button { library.importFolder(url) } label: { Label("Find New Games Now", systemImage: "arrow.clockwise") }
            }
            if BoxArtFinder.isEnabled {
                // One tap: fetch covers for every game that has none (free).
                Button { findAllMissing() } label: { Label("Find Covers", systemImage: "sparkle.magnifyingglass") }
                    .disabled(findingAll || !library.entries.contains { $0.cover == nil })
            }
            Menu {
                if BoxArtFinder.isEnabled {
                    Button { findAllMissing() } label: { Label("Find Missing Box Art", systemImage: "sparkle.magnifyingglass") }
                        .disabled(findingAll || !library.entries.contains { $0.cover == nil })
                    Button { findAllMissingTitles() } label: { Label("Find Missing Title Screens", systemImage: "tv.badge.wifi") }
                }
                Button { if Store.gate(.coverFlow) { titleGen.regenerate(library.entries, library: library) } } label: { Label("Refresh Title Screens", systemImage: "arrow.triangle.2.circlepath") }
            } label: { Label((BoxArtFinder.isEnabled ? "Box Art & Title Screens" : "Title Screens").loc, systemImage: "photo.stack") }
        }
        Section("Look") {
            Picker(selection: $libraryStyle) {
                Text("Standard").tag("standard")
                Text("Classic DS Menu").tag("classicDS")
            } label: { Label("Library Style", systemImage: "rectangle.3.group") }
            .pickerStyle(.menu)
            Button { showSkins = true } label: { Label("Skins…", systemImage: "paintpalette") }
            Menu {
                Picker("Sort By", selection: $sortRaw) {
                    ForEach(ROMLibrary.SortOrder.allCases) { Text($0.label).tag($0.rawValue) }
                }
                if !isClassic {
                    Picker("Show Games As", selection: Binding(get: { tileStyle.rawValue },
                                                               set: { if $0 == TileStyle.boxArt.rawValue || Store.gate(.coverFlow) { tileStyleRaw = $0 } })) {
                        ForEach(TileStyle.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                }
            } label: { Label("Sort & Display", systemImage: "arrow.up.arrow.down") }
            Button { showMenuColors = true } label: { Label("Menu colors…", systemImage: "paintpalette") }
            Button { showBackground = true } label: { Label("Library Background…", systemImage: "photo.on.rectangle") }
            Button { showIcons = true } label: { Label("App Icon…", systemImage: "app.badge") }
        }
        Section {
            Button { showSystem = true } label: { Label("Settings…", systemImage: "gearshape") }
            Button { showSettings = true } label: { Label("Controllers…", systemImage: "gamecontroller") }
            Button { PaywallPresenter.present() } label: { Label((store.tier == .pro ? "TwinPlay Pro ✓" : "Upgrade to Plus / Pro").loc, systemImage: "star.circle") }
            Button { showReport = true } label: { Label("Report a Game Problem…", systemImage: "exclamationmark.bubble") }
            Button { showAbout = true } label: { Label("About & Credits", systemImage: "info.circle") }
            // Required by Google's UMP for users in regulated regions (EEA/UK/CH): reopen consent.
            if privacyChoicesRequired {
                Button { Consent.showPrivacyOptions() } label: { Label("Privacy Choices", systemImage: "hand.raised") }
            }
        }
        Section {
            Menu {
                Button { open(rom: nil) } label: { Label("Test Mode (no game)", systemImage: "square.grid.3x3.fill") }
            } label: { Label("Testing", systemImage: "wrench.and.screwdriver") }
        }
    }

    /// Import entries shared by the main menu and the + button.
    @ViewBuilder private var importMenuItems: some View {
        Button { coverTarget = nil; importer = .games } label: { Label("Import Game Files…", systemImage: "doc.badge.plus") }
        Button { coverTarget = nil; importer = .folder } label: {
            Label((ROMFolder.hasFolder ? "Change Games Folder…" : "Import a Folder…").loc, systemImage: "folder.badge.plus")
        }
    }

    private func systemChip(_ title: String, tag: String) -> some View {
        let on = systemFilter == tag
        return Button { systemFilter = tag } label: {
            Text(title.loc)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(on ? Color.accentColor : Color.secondary.opacity(0.16)))
                .foregroundStyle(on ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var standardBody: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: shortLandscape ? 10 : 16) {
                    if navList.indices.contains(padFocus) {
                        GameInfoCard(entry: navList[padFocus], compact: shortLandscape)
                            .frame(maxWidth: MenuLayout.readableWidth(max(gridWidth, 320)))
                            .frame(maxWidth: .infinity)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            systemChip("All", tag: "all")
                            ForEach(GameSystem.allCases) { sys in systemChip(sys.label, tag: sys.rawValue) }
                        }
                        .padding(.horizontal, 2)
                    }

                    if findingAll {
                        HStack(spacing: 8) { ProgressView(); Text(findAllProgress).font(.footnote.weight(.semibold)) }
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .glassSurface(Capsule())
                    }

                    if library.entries.isEmpty {
                        Text("Add your own .nds, .gba, .gb, .gbc, .nes, .sfc, .smc, .n64, .z64, .v64, .3ds, .cci or .cxi games with the + button: pick files, or a whole folder (subfolders included).")
                            .foregroundStyle(.secondary)
                        ExperimentalNotice(onReport: nil).frame(maxWidth: .infinity)
                    }
                    if isCoverFlow {
                        let list = filterSystem == nil
                            ? GameSystem.allCases.flatMap { library.sorted(sort, search: search, system: $0) }
                            : library.sorted(sort, search: search, system: filterSystem)
                        if list.isEmpty {
                            if !library.entries.isEmpty {
                                Text(search.isEmpty ? String(localized: "No \(filterSystem?.label ?? "") games yet.") : String(localized: "No games match “\(search)”."))
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            CoverFlowView(entries: list,
                                          style: { (Store.allows(.coverFlow) ? ($0.styleOverride ?? tileStyle) : .boxArt) },
                                          onPlay: { open(rom: $0.url) },
                                          menu: { AnyView(menu(for: $0)) },
                                          focus: $padFocus)
                                // Portrait: the usual tall stage. Landscape phone: fill what is left
                                // of the screen under the filter row so the Play button stays visible.
                                .frame(height: shortLandscape ? max(220, viewportHeight - 58) : 540)
                        }
                    } else if filterSystem == nil {
                        // "All": one section per system.
                        ForEach(GameSystem.allCases) { sys in
                            let list = library.sorted(sort, search: search, system: sys)
                            if !list.isEmpty {
                                Text(sys.longName).font(.title3.weight(.bold))
                                grid(list)
                            }
                        }
                        if !library.entries.isEmpty && library.sorted(sort, search: search).isEmpty {
                            Text("No games match “\(search)”.").foregroundStyle(.secondary)
                        }
                    } else {
                        let list = library.sorted(sort, search: search, system: filterSystem)
                        if !library.entries.isEmpty && list.isEmpty {
                            Text(search.isEmpty ? String(localized: "No \(filterSystem?.label ?? "") games yet.") : String(localized: "No games match “\(search)”."))
                                .foregroundStyle(.secondary)
                        }
                        grid(list)
                    }

                    // Footer: experimental notice + report button, at the very bottom of the list.
                    if !library.entries.isEmpty {
                        ExperimentalNotice(compact: true, onReport: { showReport = true })
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
                            .padding(.bottom, 72)   // clear of the floating search bar / ad banner
                    }
                }
                .padding(.horizontal).padding(.vertical, shortLandscape ? 8 : 16)
                .background(GeometryReader { g in Color.clear.onAppear { gridWidth = g.size.width - 32 }
                    .onChange(of: g.size.width) { gridWidth = $0 - 32 } })
                .environment(\.colorScheme, backgroundID == "none" ? colorScheme : .dark)   // readable over the scene
            }
            .onChange(of: padFocus) { f in
                guard !isCoverFlow, navList.indices.contains(f) else { return }
                withAnimation { proxy.scrollTo(navList[f].id, anchor: .center) }
            }
            .background(GeometryReader { g in
                // Visible height = frame minus the bars laid over it (nav bar, search + hint bar inset).
                let h = g.size.height - g.safeAreaInsets.top - g.safeAreaInsets.bottom
                Color.clear.onAppear { viewportHeight = h }.onChange(of: h) { viewportHeight = $0 } })
            }
            .overlay(alignment: .bottom) {
                // Floats over the content (no layout jump) and fades out a few seconds after the last
                // touch/button press or as soon as the library scrolls; any interaction brings it back.
                if hintsVisible {
                    ControllerHintBar(items: [(.left, "Move"), (.a, "Play"), (.y, "Options"), (.x, isCoverFlow ? "Grid" : "Cover Flow"),
                                              (.l, "Filter"), (.menu, "Settings")])
                        .padding(.bottom, 6)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                        .allowsHitTesting(false)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                LibraryAdBanner()
            }
            .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { _ in hideHints() })
            .simultaneousGesture(TapGesture().onEnded { pokeHints() })
            .onAppear { pokeHints() }
            .onChange(of: padFocus) { _ in pokeHints() }
            .padScope("library") { handlePad($0) }
            .background(LibraryBackgroundView())
            .searchable(text: $search, prompt: "Search games")
            .navigationTitle("TwinPlay")
            .toolbar {
                // The large title sits on the library scene too: light-on-dark there (same rule as
                // the content), otherwise it draws black in light mode.
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .largeTitle) {
                        Text("TwinPlay").font(.largeTitle.bold()).frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(backgroundID == "none" ? Color.primary : Color.white)
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu { libraryMenuItems } label: { Image(systemName: "line.3.horizontal") }
                        .accessibilityLabel("Library menu")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { toggleLayout() } label: {
                        Image(systemName: isCoverFlow ? "square.grid.2x2" : "rectangle.stack")
                    }
                    .accessibilityLabel((isCoverFlow ? "Show as grid" : "Show as Cover Flow").loc)
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu { importMenuItems } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add games")
                }
            }
            .overlay { libraryDialog }
        }
    }

    @ViewBuilder private func menu(for entry: ROMLibrary.Entry) -> some View {
        Button { open(rom: entry.url) } label: { Label("Play", systemImage: "play.fill") }
        Button { infoEntry = entry } label: { Label("Game Info", systemImage: "info.circle") }
        Button { renameText = entry.name; renaming = entry } label: { Label("Rename", systemImage: "pencil") }
        Button { library.toggleFavorite(entry) } label: {
            entry.favorite ? Label("Remove from Favorites", systemImage: "star.slash") : Label("Add to Favorites", systemImage: "star")
        }
        if BoxArtFinder.isEnabled {
            Button { openBoxArt(entry) } label: { Label("Find Box Art", systemImage: "sparkle.magnifyingglass") }
            Button { openTitleFinder(entry) } label: { Label("Find Title Screen", systemImage: "tv") }
        }
        Menu {
            Button { library.setStyle(nil, for: entry) } label: {
                if entry.styleOverride == nil { Label("Use library setting", systemImage: "checkmark") } else { Text("Use library setting") }
            }
            ForEach(TileStyle.allCases) { st in
                Button { if Store.gate(.coverFlow) { library.setStyle(st, for: entry) } } label: {
                    if entry.styleOverride == st { Label(st.label, systemImage: "checkmark") } else { Text(st.label) }
                }
            }
        } label: { Label("Show as", systemImage: "rectangle.on.rectangle") }
        Menu {
            Button { library.setCartColor(nil, for: entry) } label: {
                if entry.cartColorOverride == nil { Label("Automatic", systemImage: "checkmark") } else { Text("Automatic") }
            }
            ForEach(CartColor.allCases) { c in
                Button { library.setCartColor(c, for: entry) } label: {
                    if entry.cartColorOverride == c { Label(c.label, systemImage: "checkmark") } else { Text(c.label) }
                }
            }
        } label: { Label("Cartridge Color", systemImage: "paintpalette") }
        Menu {
            if BoxArtFinder.isEnabled {
                Button { openBoxArt(entry) } label: { Label("Find Box Art", systemImage: "sparkle.magnifyingglass") }
            }
            Button { photoTarget = entry } label: { Label("Choose from Photos", systemImage: "photo") }
            Button { coverTarget = entry; importer = .cover } label: { Label("Choose from Files", systemImage: "folder") }
            Button {
                if let img = UIPasteboard.general.image { library.setCover(img, for: entry) }
                else { library.lastError = "The clipboard does not contain an image." }
            } label: { Label("Paste image", systemImage: "doc.on.clipboard") }
            if BoxArtFinder.isEnabled {
                Button {
                    if let u = ROMLibrary.coverSearchURL(for: entry) { browserURL = IdentifiedURL(url: u) }
                } label: { Label("Search Google Images", systemImage: "magnifyingglass") }
            }
            if entry.cover != nil {
                Button { library.resetCover(for: entry) } label: { Label("Reset to built-in icon", systemImage: "arrow.uturn.backward") }
            }
        } label: { Label("Cover", systemImage: "photo.on.rectangle") }
        Button(role: .destructive) { deleting = entry } label: { Label("Delete", systemImage: "trash") }
    }

    /// Notice / rename / delete as controller-friendly overlays.
    @ViewBuilder private var libraryDialog: some View {
        if let r = renaming {
            PadDialog(title: "Rename", text: $renameText, buttons: [
                PadDialogButton(title: "Save") { library.rename(r, to: renameText) },
                PadDialogButton(title: "Use built-in title") { library.rename(r, to: "") },
                PadDialogButton(title: "Cancel", cancel: true) {},
            ]) { renaming = nil }
        } else if let d = deleting {
            PadDialog(title: "Delete this game?", message: "The game file is removed from TwinPlay. Its saves and save states are kept.", buttons: [
                PadDialogButton(title: "Delete", destructive: true) { library.delete(d) },
                PadDialogButton(title: "Cancel", cancel: true) {},
            ]) { deleting = nil }
        } else if let msg = library.lastError ?? loadError {
            PadDialog(title: "Notice", message: msg, buttons: [
                PadDialogButton(title: "OK", cancel: true) {},
            ]) { library.lastError = nil; loadError = nil }
        }
    }

    /// Games in the order they are shown (what the controller moves through).
    private var navList: [ROMLibrary.Entry] {
        filterSystem == nil ? GameSystem.allCases.flatMap { library.sorted(sort, search: search, system: $0) }
                            : library.sorted(sort, search: search, system: filterSystem)
    }
    private var gridColumns: Int { max(1, Int((gridWidth + 16) / (128 + 16))) }

    private func pokeHints() {
        withAnimation(.easeOut(duration: 0.2)) { hintsVisible = true }
        hintsToken += 1
        let t = hintsToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if t == hintsToken { hideHints() } }
    }
    private func hideHints() {
        guard hintsVisible else { return }
        withAnimation(.easeIn(duration: 0.3)) { hintsVisible = false }
    }

    private func handlePad(_ e: PadNav) {
        pokeHints()
        guard session == nil, padMenuEntry == nil, renaming == nil, deleting == nil, library.lastError == nil, loadError == nil else { return }
        let list = navList
        let n = list.count
        func move(_ d: Int) {
            guard n > 0 else { return }
            let f = min(max(padFocus + d, 0), n - 1)
            if f != padFocus { padFocus = f; if !isCoverFlow { UISelectionFeedbackGenerator().selectionChanged() } }
        }
        switch e {
        case .left: move(-1)
        case .right: move(1)
        case .up: if !isCoverFlow { move(-gridColumns) }
        case .down: if !isCoverFlow { move(gridColumns) }
        case .a: if list.indices.contains(padFocus) { open(rom: list[padFocus].url) }
        case .b: if !search.isEmpty { search = "" }
        case .y: if list.indices.contains(padFocus) { padMenuEntry = list[padFocus] }
        case .x: toggleLayout()
        case .l, .r:
            let order = ["all"] + GameSystem.allCases.map(\.rawValue)
            let i = order.firstIndex(of: systemFilter) ?? 0
            systemFilter = order[(i + (e == .r ? 1 : order.count - 1)) % order.count]
            padFocus = 0
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .menu: showSettings = true
        }
    }

    /// The long-press menu as a list the controller can drive.
    /// Remembers the picked folder and imports everything in it.
    private func chooseFolder(_ folder: URL) {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        do { try ROMFolder.remember(folder) } catch { library.lastError = String(localized: "Could not keep access to that folder: \(error.localizedDescription)") }
        library.importFolder(ROMFolder.resolve() ?? folder)
    }

    private func padActions(for entry: ROMLibrary.Entry) -> [PadAction2] {
        var a: [PadAction2] = [
            .init(title: "Play", icon: "play.fill") { open(rom: entry.url) },
            .init(title: entry.favorite ? "Remove from Favorites" : "Add to Favorites", icon: entry.favorite ? "star.slash" : "star") { library.toggleFavorite(entry) },
            .init(title: "Cover from Photos", icon: "photo") { photoTarget = entry },
            .init(title: "Rename", icon: "pencil") { renameText = entry.name; renaming = entry },
        ]
        if BoxArtFinder.isEnabled {
            a.insert(contentsOf: [
                .init(title: "Find Box Art", icon: "sparkle.magnifyingglass") { openBoxArt(entry) },
                .init(title: "Find Title Screen", icon: "tv") { openTitleFinder(entry) },
            ], at: 1)
        }
        let styles: [TileStyle?] = [nil] + TileStyle.allCases
        let si = styles.firstIndex(of: entry.styleOverride) ?? 0
        let nextStyle = styles[(si + 1) % styles.count]
        a.append(.init(title: String(localized: "Show as: \(entry.styleOverride?.label ?? "Library setting".loc) → \(nextStyle?.label ?? "Library setting".loc)"),
                       icon: "rectangle.on.rectangle") { if Store.gate(.coverFlow) { library.setStyle(nextStyle, for: entry) } })
        let colors: [CartColor?] = [nil] + CartColor.allCases
        let ci = colors.firstIndex(of: entry.cartColorOverride) ?? 0
        let nextColor = colors[(ci + 1) % colors.count]
        a.append(.init(title: String(localized: "Cartridge color: \(entry.cartColorOverride?.label ?? "Automatic".loc) → \(nextColor?.label ?? "Automatic".loc)"),
                       icon: "paintpalette", keepsOpen: true) { library.setCartColor(nextColor, for: entry) })
        if entry.cover != nil {
            a.append(.init(title: "Reset cover", icon: "arrow.uturn.backward") { library.resetCover(for: entry) })
        }
        a.append(.init(title: "Delete", icon: "trash", destructive: true) { deleting = entry })
        return a
    }

    private func grid(_ list: [ROMLibrary.Entry]) -> some View {
        LazyVGrid(columns: columns, spacing: 18) {
            ForEach(list) { entry in
                GameTile(entry: entry, style: (Store.allows(.coverFlow) ? (entry.styleOverride ?? tileStyle) : .boxArt))
                    .padFocus(pad.connected && navList.indices.contains(padFocus) && navList[padFocus].id == entry.id)
                    .id(entry.id)
                    .onTapGesture { open(rom: entry.url) }
                    .contextMenu { menu(for: entry) }
                    .onDrop(of: [UTType.image], isTargeted: nil) { providers in
                        dropCover(providers, on: entry)
                    }
            }
        }
    }

    /// Applies the best online title-screen match (libretro Named_Titles) to every game that has
    /// no chosen title image. Games without a confident match keep their captured title screen.
    private func findAllMissingTitles() {
        let targets = library.entries.filter { $0.titleImage == nil }
        guard !targets.isEmpty, !findingAll else { return }
        findingAll = true
        Task {
            var found = 0
            for (i, entry) in targets.enumerated() {
                await MainActor.run { findAllProgress = "\(i + 1)/\(targets.count)" }
                guard let best = try? await BoxArtFinder.shared.candidates(for: library.boxArtQuery(for: entry), kind: .title, limit: 1).first,
                      best.score >= BoxArtFinder.autoApplyScore,
                      let img = try? await BoxArtFinder.shared.image(for: best) else { continue }
                await MainActor.run { library.setTitleImage(img, for: entry) }
                found += 1
            }
            await MainActor.run {
                findingAll = false
                library.lastError = String(localized: "Found title screens online for \(found) of \(targets.count) games. The others use the screen TwinPlay captured.")
            }
        }
    }

    /// Applies the best box-art match to every game without a cover (only confident matches).
    private func findAllMissing() {
        let targets = library.entries.filter { $0.cover == nil }
        guard !targets.isEmpty else { return }
        findingAll = true
        Task {
            var found = 0
            for (i, entry) in targets.enumerated() {
                await MainActor.run { findAllProgress = "\(i + 1)/\(targets.count)" }
                guard let best = try? await BoxArtFinder.shared.candidates(for: library.boxArtQuery(for: entry), kind: .boxart, limit: 1).first,
                      best.score >= BoxArtFinder.autoApplyScore,
                      let img = try? await BoxArtFinder.shared.image(for: best) else { continue }
                await MainActor.run { library.setCover(img, for: entry) }
                found += 1
            }
            await MainActor.run {
                findingAll = false
                let missing = targets.count - found
                library.lastError = missing == 0 ? String(localized: "Found art for all \(found) games.")
                    : String(localized: "Found art for \(found) of \(targets.count) games. For the rest, use Find Box Art on the game.")
            }
        }
    }

    private func setCover(fromFile url: URL, for entry: ROMLibrary.Entry) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let data = try? Data(contentsOf: url), let img = UIImage(data: data) { library.setCover(img, for: entry) }
        else { library.lastError = "Could not read that image." }
    }

    private func dropCover(_ providers: [NSItemProvider], on entry: ROMLibrary.Entry) -> Bool {
        guard let p = providers.first(where: { $0.canLoadObject(ofClass: UIImage.self) }) else { return false }
        p.loadObject(ofClass: UIImage.self) { obj, _ in
            guard let img = obj as? UIImage else { return }
            DispatchQueue.main.async { library.setCover(img, for: entry) }
        }
        return true
    }

    private func open(rom: URL?) {
        // #19: fetch this game's newest save / states from iCloud first (gives up after ~2.5 s).
        guard let rom, !openingFromCloud else { if rom == nil { start(rom: nil) }; return }
        openingFromCloud = true
        CloudSaveSync.shared.pullBeforePlaying(rom: rom) {
            openingFromCloud = false
            guard session == nil else { return }
            start(rom: rom)
        }
    }

    private func start(rom: URL?) {
        do {
            reviewClock.begin()
            session = try EmulatorSession(romURL: rom, statesDirectory: library.statesDirectory,
                                           saveURL: rom.map { library.saveURL(for: $0) },
                                           biosURL: library.arm7BIOSURL)
            if let rom { library.markPlayed(rom); playStart = (rom, Date()); CloudSaveSync.shared.setPlaying(saveFile: library.saveURL(for: rom)) }
        } catch {
            loadError = error.localizedDescription
        }
    }
}

struct IdentifiedURL: Identifiable { let url: URL; var id: String { url.absoluteString } }

/// One game in the grid, drawn in the chosen style, with a DS/GBA badge.
struct GameTile: View {
    let entry: ROMLibrary.Entry
    var style: TileStyle = .boxArt

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                if style == .cartridge {
                    GameArtwork(entry: entry, style: .cartridge)
                        .aspectRatio(1, contentMode: .fit)
                } else {
                    GameArtwork(entry: entry, style: style)
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.black.opacity(0.08)))
                }
                SystemBadge(system: entry.system).padding(6)
                if entry.favorite {
                    Image(systemName: "star.fill").font(.caption.weight(.bold)).foregroundStyle(.yellow)
                        .shadow(color: .black.opacity(0.4), radius: 1.5).padding(7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Favorite")
                }
            }
            Text(entry.name).font(.footnote.weight(.semibold)).lineLimit(2).multilineTextAlignment(.center)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// PHPickerViewController wrapper (no photo-library permission needed).
struct PhotoPicker: UIViewControllerRepresentable {
    let onPick: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let vc = PHPickerViewController(configuration: config)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: (UIImage?) -> Void
        init(onPick: @escaping (UIImage?) -> Void) { self.onPick = onPick }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let p = results.first?.itemProvider, p.canLoadObject(ofClass: UIImage.self) else { onPick(nil); return }
            p.loadObject(ofClass: UIImage.self) { obj, _ in
                DispatchQueue.main.async { self.onPick(obj as? UIImage) }
            }
        }
    }
}

/// In-app browser for searching cover images; the user saves one to Photos/Files and picks it.
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}

/// One row of the controller action sheet.
struct PadAction2: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    var destructive = false
    var keepsOpen = false
    let run: () -> Void
}

/// The long-press menu as a sheet: D-pad up/down to pick, A to choose, B to close.
struct PadActionsSheet: View {
    let entry: ROMLibrary.Entry
    let actions: [PadAction2]
    let close: () -> Void
    @State private var focus = 0
    @EnvironmentObject private var library: ROMLibrary

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(currentActions.enumerated()), id: \.offset) { i, a in
                        Button { choose(i) } label: {
                            Label(a.title.loc, systemImage: a.icon).foregroundStyle(a.destructive ? .red : .primary)
                        }
                        .listRowBackground(i == focus ? Color.accentColor.opacity(0.25) : Color(.secondarySystemGroupedBackground))
                        .id(i)
                    }
                }
                .onChange(of: focus) { f in withAnimation { proxy.scrollTo(f) } }
            }
            .navigationTitle(entry.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", action: close) } }
            .safeAreaInset(edge: .bottom) { ControllerHintBar(items: [(.up, "Move"), (.a, "Choose"), (.b, "Close")]) }
        }
        .presentationDetents([.medium, .large])
        .padScope("pad-actions") { e in
            switch e {
            case .up: focus = max(0, focus - 1); UISelectionFeedbackGenerator().selectionChanged()
            case .down: focus = min(currentActions.count - 1, focus + 1); UISelectionFeedbackGenerator().selectionChanged()
            case .a: choose(focus)
            case .b, .y: close()
            default: break
            }
        }
    }

    /// Rebuilt from the live entry so "cycle" rows show the new value.
    private var currentActions: [PadAction2] { actions }

    private func choose(_ i: Int) {
        guard currentActions.indices.contains(i) else { return }
        let a = currentActions[i]
        if a.keepsOpen { a.run(); return }
        close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { a.run() }   // after the sheet is gone
    }
}


/// Classic DS Menu "+ Add Games" pill: always one line; shrinks to an icon-only "+" when space is tight.
struct AddGamesLabel: View {
    var body: some View {
        ViewThatFits(in: .horizontal) {
            Label("Add Games", systemImage: "plus")
                .lineLimit(1).fixedSize()
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(ClassicPalette.text)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .glassSurface(Capsule(), interactive: true)
            Image(systemName: "plus").font(.system(size: 14, weight: .bold)).foregroundStyle(ClassicPalette.text)
                .frame(width: 34, height: 28)
                .glassSurface(Capsule(), interactive: true)
        }
    }
}
