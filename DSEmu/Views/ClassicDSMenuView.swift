// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import SwiftUI

/// "Classic DS Menu" library style: a two-screen launcher. The top screen shows a status bar and a
/// large card for the selected game (art, title, stats); the bottom (touch) screen has the folder
/// name, a speech-bubble label, a carousel of rounded icons with the selected one enlarged and a
/// START tag, a scroll bar with an "N/M" count and Back / Fav buttons.
/// On an open iPhone Duo the two halves sit on either side of the hinge; on a regular iPhone or a
/// closed Duo they are stacked in one compact column. All artwork is original TwinPlay styling.
struct ClassicDSMenuView: View {
    enum Folder: String, CaseIterable { case all, ds, gba, gb, gbc, nes, snes, n64, n3ds, favorites
        /// The system a folder holds (nil: All / Favorites hold every system).
        var system: GameSystem? {
            switch self {
            case .ds: return .ds
            case .gba: return .gba
            case .gb: return .gb
            case .gbc: return .gbc
            case .nes: return .nes
            case .snes: return .snes
            case .n64: return .n64
            case .n3ds: return .n3ds
            default: return nil
            }
        }
        /// Games of this folder, in the given order. All keeps every game of every system.
        func filter(_ entries: [ROMLibrary.Entry]) -> [ROMLibrary.Entry] {
            switch self {
            case .all: return entries
            case .favorites: return entries.filter(\.favorite)
            default: return entries.filter { $0.system == system }
            }
        }
        var title: String { englishTitle.loc }
        /// English source text (the String Catalog key).
        var englishTitle: String {
            switch self {
            case .all: return "All Games"
            case .ds: return "DS"
            case .gba: return "Game Boy Advance"
            case .gb: return "Game Boy"
            case .gbc: return "Game Boy Color"
            case .nes: return "NES"
            case .snes: return "Super NES"
            case .n64: return "N64"
            case .n3ds: return "3DS"
            case .favorites: return "Favorites"
            }
        }
        var icon: String {
            switch self {
            case .all: return "square.grid.2x2.fill"
            case .ds: return "rectangle.split.1x2.fill"
            case .gba: return "rectangle.landscape.rotate"
            case .gb: return "rectangle.portrait.fill"
            case .gbc: return "rectangle.portrait.on.rectangle.portrait.fill"
            case .nes: return "rectangle"
            case .snes: return "rectangle.inset.filled"
            case .n64: return "gamecontroller"
            case .n3ds: return "rectangle.split.2x1"
            case .favorites: return "star.fill"
            }
        }
    }

    let entries: [ROMLibrary.Entry]
    @Binding var folder: Folder
    @Binding var focus: Int
    let posture: FoldPosture
    /// The device has a hinge (iPhone Duo), whatever the posture.
    var hingeKnown = false
    let onPlay: (ROMLibrary.Entry) -> Void
    let onFavorite: (ROMLibrary.Entry) -> Void
    let onOptions: (ROMLibrary.Entry) -> Void
    let menu: AnyView
    var onMenu: () -> Void = {}
    /// False while something covers the menu (a running game, a sheet): controller input is ignored.
    var controllerEnabled = true

    static let pageSize = 5
    @StateObject private var grid = ClassicGridModel()
    @State private var pendingFocus: URL?
    @State private var showColors = false
    @AppStorage("classicLayoutMode") private var layoutMode = "carousel"     // carousel | grid
    @AppStorage(ClassicMenuTheme.key) private var themeRaw = ClassicMenuTheme.defaultTheme.rawValue
    @AppStorage("classicGridColumns") private var gridColumns = 4            // 3...6
    private var bubbleFallback: String {
        guard isGrid, !entries.isEmpty else { return "—" }
        return grid.selectedSlot?.kind == .folder ? (grid.selectedSlot?.name ?? "Folder".loc) : "Empty slot".loc
    }
    private var isGrid: Bool { layoutMode == "grid" }
    private var cols: Int { min(max(gridColumns, 3), 6) }
    private var selected: ROMLibrary.Entry? {
        if isGrid { return grid.selectedEntry }
        return entries.indices.contains(focus) ? entries[focus] : nil
    }

    var body: some View {
        content
            .id(themeRaw)        // a new colour theme redraws every part of the menu
    }

    private var duoWindow: Bool { OuterDisplay.duoWindow(hingeKnown: hingeKnown, posture: posture) }

    /// How the two library "screens" are arranged.
    enum Arrangement: Equatable { case hingeSplit, stacked, sideBySide, compact }

    /// iPhone Duo: always the portrait arrangement (info on top, games below) filling the
    /// display: split at the hinge when open in portrait, plain stacked otherwise (landscape,
    /// closed, posture unknown). Regular iPhone: side by side in landscape, compact in portrait.
    static func arrangement(posture: FoldPosture, duo: Bool, size: CGSize) -> Arrangement {
        let portrait = size.height >= size.width
        if (posture == .book || posture == .open) && portrait { return .hingeSplit }
        if duo { return .stacked }
        return portrait ? .compact : .sideBySide
    }

    private var content: some View {
        GeometryReader { geo in
            let full = geo.size
            // #3b: the window's size (not the safe-area-reduced one) tells a Duo apart.
            let duo = duoWindow || (OuterDisplay.isPhone && OuterDisplay.isDuo(hingeKnown: hingeKnown, posture: posture, windowSize: full))
            switch Self.arrangement(posture: posture, duo: duo, size: full) {
            case .hingeSplit:
                // Open Duo in portrait: top panel above the hinge, bottom panel below it. The
                // hinge is only trusted when it fits this window (else the middle of the display).
                let hinge = FoldGeometry.hinge(in: geo) ?? FoldGeometry.defaultHinge(full: full)
                VStack(spacing: 0) {
                    topScreen.frame(height: max(0, hinge.minY))
                    ClassicHingeBand().frame(height: hinge.height)
                    bottomScreen.frame(maxHeight: .infinity)
                }
            case .stacked:
                // Duo in landscape, or closed: the portrait layout (game info on top, carousel /
                // grid below) filling the whole display. Never two narrow side-by-side panels.
                VStack(spacing: 10) {
                    topScreen.frame(height: min(full.height * 0.44, 380))
                    bottomScreen.frame(maxHeight: .infinity)
                }
                .padding(.horizontal, 10).padding(.vertical, full.width > full.height ? 6 : 0)
                .frame(width: full.width, height: full.height)
            case .sideBySide:
                // Regular iPhone in landscape: the two "screens" sit side by side so the bottom one
                // keeps its full height for the icons and the hint bar.
                HStack(spacing: 10) {
                    topScreen.frame(width: full.width * 0.42)
                    bottomScreen.frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            case .compact:
                // Regular iPhone portrait: compact stacked layout.
                VStack(spacing: 10) {
                    topScreen.frame(height: min(full.height * 0.44, 380))
                    bottomScreen.frame(maxHeight: .infinity)
                }
                .padding(.horizontal, 10)
            }
        }
        .background(ClassicPalette.body.ignoresSafeArea())
        .padScope("library-classic") { e in if controllerEnabled && !showColors { handle(e) } }
        .onChange(of: entries.count) { n in if focus >= n { focus = max(0, n - 1) } }
        // Reload the grid from the *new* values handed to onChange: the folder and its games change
        // together, and reading them from the captured view could pair the new folder with the old
        // folder's games (that is how GBA games once showed up, and got saved, under "Game Boy").
        .onAppear { reloadGrid(GridInput(folder: folder, entries: entries)) }
        #if DEBUG
        // Testing aid (screenshots): -TwinPlayOpenColors <seconds> opens the menu-colors popover.
        .onAppear {
            let d = UserDefaults.standard.double(forKey: "TwinPlayOpenColors")
            if d > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + d) { showColors = true } }
        }
        #endif
        .onChange(of: GridInput(folder: folder, entries: entries)) { input in
            reloadGrid(input)
            // After Back to All Games, stay on the game that was selected in the folder.
            if let k = pendingFocus, input.folder == .all, let i = input.entries.firstIndex(where: { $0.id == k }) {
                pendingFocus = nil; focus = i
                if isGrid, let gi = grid.visible.firstIndex(where: { $0.game == k.lastPathComponent }) { grid.select(gi) }
            }
        }
        .onChange(of: grid.selected) { _ in syncFocus() }
        .onChange(of: grid.openFolder) { _ in syncFocus() }
    }

    // MARK: Top screen

    private var topScreen: some View {
        ClassicScreenPanel {
            VStack(spacing: 10) {
                ClassicStatusBar(menu: menu, trailingClearance: OuterDisplay.pillClearance(duo: duoWindow))
                if let e = selected {
                    ClassicGameCard(entry: e)
                } else if isGrid, !entries.isEmpty {
                    Spacer()
                    let s = grid.selectedSlot
                    Image(systemName: s?.kind == .folder ? "folder.fill" : "square.dashed").font(.system(size: 44)).foregroundStyle(ClassicPalette.dim)
                    Text(s?.kind == .folder ? (s?.name ?? "Folder".loc) : "Empty slot".loc)
                        .font(.system(.title3, design: .rounded).weight(.bold)).foregroundStyle(ClassicPalette.text)
                    Text(s?.kind == .folder ? String(localized: "\(s?.items?.count ?? 0) games \u{2022} tap again or press A to open") : (grid.editing ? "Drag an icon here" : "Tap Edit (or long-press an icon) to arrange").loc)
                        .font(.system(.callout, design: .rounded)).foregroundStyle(ClassicPalette.dim)
                    Spacer()
                } else {
                    Spacer()
                    Text((folder == .favorites ? "No favorites yet.\nPress Fav on a game to add it." : "No games here yet.\nImport your own .nds, .gba, .gb, .gbc, .nes, .sfc, .smc, .n64, .z64, .v64, .3ds, .cci or .cxi files.").loc)
                        .multilineTextAlignment(.center).font(.system(.callout, design: .rounded)).foregroundStyle(ClassicPalette.dim)
                    Spacer()
                }
            }
            .padding(12)
        }
    }

    // MARK: Bottom screen

    private var bottomScreen: some View {
        ClassicScreenPanel {
            GeometryReader { bg in
            let tight = bg.size.height < 330
            VStack(spacing: tight ? 4 : 8) {
                HStack(spacing: 6) {
                    Button { cycleFolder(-1) } label: { Image(systemName: "chevron.left") }
                    Image(systemName: folder.icon).font(.caption)
                    Text(grid.folderTitle.map { "\(folder.title) \u{203A} \($0)" } ?? folder.title)
                        .font(.system(.subheadline, design: .rounded).weight(.semibold)).lineLimit(1)
                    Spacer()
                    Button { cycleFolder(1) } label: { Image(systemName: "chevron.right") }
                }
                .foregroundStyle(ClassicPalette.text)
                .buttonStyle(.plain)
                .accessibilityElement(children: .contain)

                viewControls

                ClassicBubble(compact: tight, title: selected?.name ?? bubbleFallback, subtitle: selected.map(ClassicGameCard.subtitle) ?? (isGrid && grid.selectedSlot?.kind == .folder ? String(localized: "\(grid.selectedSlot?.items?.count ?? 0) games") : ""))

                if isGrid {
                    ClassicGridView(model: grid, columns: cols, onPlay: onPlay)
                        .frame(minHeight: 0, maxHeight: .infinity)
                } else {
                    carousel.frame(minHeight: 0, maxHeight: .infinity)
                    ClassicScrollBar(index: focus, count: entries.count)
                }

                if isGrid && grid.editing {
                    Text((tight ? "Drag icons to move \u{2022} drop on a folder to add" : "Drag an icon to any spot (or onto a folder). Controller: A pick up / drop, B cancel.").loc)
                        .font(.system(.caption2, design: .rounded)).foregroundStyle(ClassicPalette.dim)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    editBar
                } else {
                HStack {
                    if canGoBack {
                        ClassicPillButton(glyph: "B", label: "Back") { goBack() }   // hidden at All Games
                    }
                    Spacer()
                    if let e = selected {
                        ClassicPillButton(glyph: "Y", label: e.favorite ? "Unfav" : "Fav", star: e.favorite) { onFavorite(e) }
                    }
                }
                .layoutPriority(1)          // the hint bar never gets squeezed out
                }
                // Below the carousel and the Back / Fav controls. The icon row shrinks first.
                LibraryAdBanner()
                    .layoutPriority(2)
            }
            .padding(tight ? 8 : 12)
            .frame(width: bg.size.width, height: bg.size.height)
            }
        }
    }

    /// View row: a labelled Carousel/Grid switch, the Colors pill (#23, menu colour themes) and in
    /// grid mode the icon size and Edit/Done. On narrow screens the labels shrink to icons.
    private var viewControls: some View {
        ViewThatFits(in: .horizontal) {
            viewControlsRow(level: 0)
            viewControlsRow(level: 1)
            viewControlsRow(level: 2)
            viewControlsRow(level: 3)
            ScrollView(.horizontal, showsIndicators: false) { viewControlsRow(level: 3) }
        }
        .menuColorsPopover(isPresented: $showColors)
    }

    /// level 0: every label; 1: Carousel / Grid as icons; 2: Colors / Size as icons too; 3: tighter spacing.
    @ViewBuilder private func viewControlsRow(level: Int) -> some View {
        let compact = level >= 2
        HStack(spacing: level >= 3 ? 3 : 6) {
            HStack(spacing: 0) {
                modeSegment("Carousel", "rectangle.split.3x1", on: !isGrid, compact: level >= 1) { setMode("carousel") }
                modeSegment("Grid", "square.grid.3x3", on: isGrid, compact: level >= 1) { setMode("grid") }
            }
            .glassSurface(Capsule(), interactive: true)
            .overlay(Capsule().strokeBorder(ClassicPalette.line))
            .fixedSize()
            Spacer(minLength: 4)
            Button { showColors = true } label: { chipLabel("Colors", "paintpalette", on: showColors, iconOnly: compact) }
                .accessibilityLabel("Menu colors")
            if isGrid {
                Menu {
                    Picker("Icon size", selection: $gridColumns) {
                        Text("Large (3 across)").tag(3); Text("Medium (4 across)").tag(4)
                        Text("Small (5 across)").tag(5); Text("Tiny (6 across)").tag(6)
                    }
                } label: { chipLabel("Size", "textformat.size", on: false, iconOnly: compact) }
                .accessibilityLabel("Icon size")
                Button {
                    withAnimation(.spring(response: 0.3)) { if grid.editing { grid.cancelCarryIfNeeded() }; grid.editing.toggle() }
                } label: { chipLabel(grid.editing ? "Done" : "Edit", grid.editing ? "checkmark" : "pencil", on: grid.editing) }
                .accessibilityLabel((grid.editing ? "Done editing" : "Edit icon layout").loc)
            }
        }
        .buttonStyle(.plain)
    }
    private func setMode(_ m: String) {
        guard layoutMode != m else { return }
        withAnimation(.spring(response: 0.3)) { layoutMode = m; grid.editing = false }
        syncFocus()
    }
    private func modeSegment(_ t: String, _ icon: String, on: Bool, compact: Bool = false, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Group { if compact { Image(systemName: icon).frame(minWidth: 18) } else { Label(t.loc, systemImage: icon) } }
                .font(.system(.caption, design: .rounded).weight(.bold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(on ? ClassicPalette.accent : Color.clear))
                .foregroundStyle(on ? Color.black : ClassicPalette.text)
        }
        .accessibilityLabel(String(localized: "\(t.loc) view")).accessibilityAddTraits(on ? .isSelected : [])
    }
    private func chipLabel(_ t: String, _ icon: String, on: Bool, iconOnly: Bool = false) -> some View {
        Group {
            if iconOnly { Image(systemName: icon).frame(minWidth: 18) } else { Label(t.loc, systemImage: icon) }
        }
        .font(.system(.caption, design: .rounded).weight(.bold))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .glassSurface(Capsule(), interactive: true, tint: on ? ClassicPalette.accent : nil)
            .overlay(Capsule().strokeBorder(ClassicPalette.line))
            .foregroundStyle(on ? Color.black : ClassicPalette.text)
    }

    /// Edit-mode tools (grid only).
    private var editBar: some View {
        let s = grid.selectedSlot
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if grid.openFolder == nil {
                    editButton("+ Folder", "folder.badge.plus") { grid.addFolder() }
                    editButton("+ Gap", "square.dashed") { grid.addEmpty() }
                    if s?.kind == .empty { editButton("Remove gap", "minus.square") { grid.removeSelectedEmptyOrFolder() } }
                    if s?.kind == .folder {
                        editButton("Rename", "pencil") { grid.renaming = s?.id }
                        editButton("Unfolder", "folder.badge.minus") { grid.removeSelectedEmptyOrFolder() }
                    }
                } else {
                    if s != nil { editButton("Take out", "arrow.up.forward.square") { grid.takeOutOfFolder() } }
                    editButton("Close folder", "folder") { grid.closeFolder() }
                }
            }
        }
    }
    private func editButton(_ t: String, _ icon: String, prominent: Bool = false, _ act: @escaping () -> Void) -> some View {
        Button(action: { withAnimation(.spring(response: 0.3)) { act() } }) {
            Label(t.loc, systemImage: icon).font(.system(.caption, design: .rounded).weight(.bold))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .glassSurface(Capsule(), interactive: true, tint: prominent ? ClassicPalette.accent : nil)
                .overlay(Capsule().strokeBorder(ClassicPalette.line))
                .foregroundStyle(prominent ? Color.black : ClassicPalette.text)
        }.buttonStyle(.plain)
    }

    struct GridInput: Equatable { let folder: Folder; let entries: [ROMLibrary.Entry] }
    private func reloadGrid(_ input: GridInput) {
        // Only games that really belong to the folder (guards the saved layout too).
        grid.load(key: input.folder.rawValue, entries: input.folder.filter(input.entries))
        #if DEBUG
        let d = UserDefaults.standard
        if d.bool(forKey: "TwinPlayClassicGridDemo"), grid.openFolder == nil, !grid.slots.contains(where: { $0.kind == .folder }), grid.slots.count > 3 {
            grid.selected = 2; grid.addFolder()
            if let g = grid.slots[3].game, let i = grid.slots.firstIndex(where: { $0.id == "g-" + g }) { _ = grid.put(id: grid.slots[i].id, intoFolder: 2) }
            grid.selected = 1; grid.addEmpty()
        }
        if d.bool(forKey: "TwinPlayClassicGridEdit") { grid.editing = true }
        if d.integer(forKey: "TwinPlayClassicGridSelect") > 0 { grid.selected = d.integer(forKey: "TwinPlayClassicGridSelect") }
        if d.bool(forKey: "TwinPlayClassicGridCarry") { grid.toggleCarry(); grid.select(grid.selected + 1) }
        #endif
    }
    private func syncFocus() {
        guard isGrid, let e = grid.selectedEntry, let i = entries.firstIndex(where: { $0.id == e.id }) else { return }
        if focus != i { focus = i }
    }

    private var carousel: some View {
        GeometryReader { g in
            // The selected icon is drawn 1.35x with a START tag below it (~0.2 of its size), so the
            // strip is sized from whichever is tighter: the width (5 icons) or the height.
            let big = max(24, min(g.size.width / 5.2 * 1.35, g.size.height / 1.22))
            let slot = big / 1.35
            let spacing = slot * 0.18
            // The strip is laid out explicitly so the selected icon is always centred, whatever the
            // list length or when it changes (no scroll-position state to get out of sync).
            let f = entries.isEmpty ? 0 : min(max(focus, 0), entries.count - 1)
            let startX = g.size.width / 2 - big / 2 - CGFloat(f) * (slot + spacing)
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { i, e in
                    ClassicIconTile(entry: e, selected: i == focus, size: i == focus ? big : slot)
                        .frame(width: i == focus ? big : slot)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if i == focus { onPlay(e) } else { withAnimation(.spring(response: 0.3)) { focus = i } }
                            UISelectionFeedbackGenerator().selectionChanged()
                        }
                        .onLongPressGesture { onOptions(e) }
                        .accessibilityLabel(e.name)
                        .accessibilityHint((i == focus ? "Double-tap to start" : "Select").loc)
                }
            }
            .fixedSize()
            .offset(x: startX)
            .frame(width: g.size.width, height: g.size.height, alignment: .leading)
            .clipped()
            .contentShape(Rectangle())
            .animation(.spring(response: 0.3), value: focus)
            .gesture(DragGesture(minimumDistance: 20).onEnded { v in
                let steps = Int((-v.translation.width / (slot * 0.9)).rounded())
                if steps != 0 { move(steps) }
            })
        }
    }


    // MARK: Actions (also used by the controller)

    func move(_ d: Int) {
        guard !entries.isEmpty else { return }
        let f = min(max(focus + d, 0), entries.count - 1)
        if f != focus { withAnimation(.spring(response: 0.3)) { focus = f }; UISelectionFeedbackGenerator().selectionChanged() }
    }
    func cycleFolder(_ d: Int) {
        let all = Folder.allCases
        let i = all.firstIndex(of: folder) ?? 0
        folder = all[(i + d + all.count) % all.count]
        focus = 0
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    /// Back: closes an open grid folder, else leaves a system folder for All Games (keeping the
    /// selected game selected). At the root it does nothing: it never quits, resets or switches style.
    var canGoBack: Bool { folder != .all || (isGrid && grid.openFolder != nil) }
    func goBack() {
        if isGrid && grid.openFolder != nil { withAnimation { grid.closeFolder() }; return }
        guard folder != .all else { return }
        let keep = selected?.id
        folder = .all
        pendingFocus = keep
        focus = 0
    }

    /// Controller: D-pad/stick left-right move, up/down change folder, A start, B back, Y fav, L/R page.
    func handle(_ e: PadNav) {
        if isGrid { handleGrid(e); return }
        switch e {
        case .left: move(-1)
        case .right: move(1)
        case .up: cycleFolder(-1)
        case .down: cycleFolder(1)
        case .l: move(-Self.pageSize)
        case .r: move(Self.pageSize)
        case .a: if let s = selected { onPlay(s) }
        case .b: goBack()
        case .y: if let s = selected { onFavorite(s) }
        case .x: if let s = selected { onOptions(s) }
        case .menu: onMenu()
        }
    }
}

extension ClassicDSMenuView {
    /// Controller in grid mode. D-pad moves the cursor (rows and pages); L/R flip pages; A starts a
    /// game or opens a folder; X arranges. While arranging, A picks an icon up / drops it, the D-pad
    /// carries it, B puts it back where it was (or leaves edit mode).
    func handleGrid(_ e: PadNav) {
        let c = cols, pp = max(grid.perPage, 1)
        switch e {
        case .left: grid.select(grid.selected - 1)
        case .right: grid.select(grid.selected + 1)
        case .up:
            if grid.selected % pp < c { if !grid.editing && grid.openFolder == nil { cycleFolder(-1) } } else { grid.select(grid.selected - c) }
        case .down:
            if grid.selected % pp >= pp - c { if !grid.editing && grid.openFolder == nil { cycleFolder(1) } } else { grid.select(grid.selected + c) }
        case .l: grid.select(grid.selected - pp)
        case .r: grid.select(grid.selected + pp)
        case .a:
            if grid.editing { withAnimation(.spring(response: 0.25)) { grid.toggleCarry() } }
            else if grid.selectedSlot?.kind == .folder { withAnimation { grid.openSelectedFolder() } }
            else if let s = selected { onPlay(s) }
        case .b:
            if grid.carried != nil { withAnimation { grid.cancelCarry() } }
            else if grid.editing { grid.editing = false }
            else if grid.openFolder != nil { withAnimation { grid.closeFolder() } }
            else { goBack() }
        case .x:
            if grid.editing { grid.cancelCarryIfNeeded(); grid.editing = false } else if grid.selectedSlot?.kind == .game { grid.editing = true }
        case .y: if let s = selected, !grid.editing { onFavorite(s) }
        case .menu: onMenu()
        }
    }
}

// MARK: - Pieces

/// Classic DS Menu colours, from the theme picked in Settings ▸ Library (`classicMenuTheme`).
enum ClassicPalette {
    static var theme: ClassicMenuTheme { ClassicMenuTheme.current }
    static var body: LinearGradient { LinearGradient(colors: [theme.bodyTop.color, theme.bodyBottom.color], startPoint: .top, endPoint: .bottom) }
    static var screen: LinearGradient { LinearGradient(colors: [theme.screenTop.color, theme.screenBottom.color], startPoint: .top, endPoint: .bottom) }
    static let panel = Color.white.opacity(0.07)
    static let line = Color.white.opacity(0.18)
    static var text: Color { theme.text.color }
    static var dim: Color { theme.dim.color }
    static var accent: Color { theme.accent.color }
}

/// An sRGB colour as plain numbers (testable without SwiftUI).
struct RGB: Equatable {
    var r, g, b: Double
    init(_ hex: UInt32) { r = Double((hex >> 16) & 0xFF) / 255; g = Double((hex >> 8) & 0xFF) / 255; b = Double(hex & 0xFF) / 255 }
    var color: Color { Color(red: r, green: g, blue: b) }
    /// WCAG relative luminance.
    var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }
    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let l1 = max(a.luminance, b.luminance), l2 = min(a.luminance, b.luminance)
        return (l1 + 0.05) / (l2 + 0.05)
    }
}

/// Colour themes for the Classic DS Menu library.
enum ClassicMenuTheme: String, Identifiable {
    case twinplay, midnight, cobalt, crimson, emerald, grape, sunset, graphite
    case lagoon, amber, rose, glacier, ink, sand, violet, copper
    case custom
    /// Swatches. Custom is a ColorPicker, not one of these.
    static let allCases: [ClassicMenuTheme] = [
        .twinplay, .midnight, .cobalt, .crimson, .emerald, .grape, .sunset, .graphite,
        .lagoon, .amber, .rose, .glacier, .ink, .sand, .violet, .copper,
    ]
    static let key = "classicMenuTheme"
    static let customColorKey = "twinplay.menuCustomColor"
    static let defaultTheme: ClassicMenuTheme = .twinplay
    var id: String { rawValue }
    static var current: ClassicMenuTheme {
        let raw = UserDefaults.standard.string(forKey: key) ?? ""
        if raw == ClassicMenuTheme.custom.rawValue { return .custom }
        return ClassicMenuTheme(rawValue: raw) ?? defaultTheme
    }

    var label: String { englishLabel.loc }
    /// English source text (the String Catalog key).
    var englishLabel: String {
        switch self {
        case .twinplay: return "TwinPlay Teal"
        case .midnight: return "Midnight"
        case .cobalt: return "Cobalt"
        case .crimson: return "Crimson"
        case .emerald: return "Emerald"
        case .grape: return "Grape"
        case .sunset: return "Sunset"
        case .graphite: return "Graphite"
        case .lagoon: return "Lagoon"
        case .amber: return "Amber"
        case .rose: return "Rose"
        case .glacier: return "Glacier"
        case .ink: return "Ink"
        case .sand: return "Sand"
        case .violet: return "Violet"
        case .copper: return "Copper"
        case .custom: return "Custom"
        }
    }
    // (body top, body bottom, screen top, screen bottom, text, dim, accent)
    private var hex: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32) {
        switch self {
        case .twinplay: return (0x0B2B36, 0x06161D, 0x10566A, 0x0A3644, 0xEAFBFF, 0xA3D9E5, 0xFFB703)
        case .midnight: return (0x1C1F29, 0x12141C, 0x263854, 0x1A263D, 0xEBF2FF, 0x9EB3D1, 0xFFC740)
        case .cobalt:   return (0x0E1F4A, 0x08122E, 0x1E44A0, 0x132C70, 0xF2F6FF, 0xB0C4EE, 0xFFD23F)
        case .crimson:  return (0x3A0B12, 0x22060A, 0x7E1729, 0x5A0F1B, 0xFFF1F2, 0xF3B1BB, 0xFFC857)
        case .emerald:  return (0x072A1E, 0x041A12, 0x11603F, 0x0A402C, 0xEFFFF7, 0xA6DCC4, 0xFFE066)
        case .grape:    return (0x24103F, 0x160A28, 0x4E2C8A, 0x36206A, 0xF6F0FF, 0xCBB9EE, 0x7CFFCB)
        case .sunset:   return (0x3B1A06, 0x241003, 0x9A430E, 0x72310A, 0xFFF6EE, 0xF4C7A6, 0x4FD1FF)
        case .graphite: return (0x2A2A2D, 0x18181A, 0x46464C, 0x323236, 0xF4F4F6, 0xBDBDC4, 0xFF6B6B)
        case .lagoon:   return (0x063044, 0x031820, 0x0E5A72, 0x084056, 0xF3FCFF, 0xB7DCE8, 0xFFD166)
        case .amber:    return (0x3A2404, 0x241602, 0x8A5A10, 0x6A4208, 0xFFF8EC, 0xF0D2A4, 0x7EE0FF)
        case .rose:     return (0x3A1020, 0x240814, 0x8A3058, 0x641E3C, 0xFFF5F8, 0xF3C0D2, 0xFFE08A)
        case .glacier:  return (0x10243A, 0x081624, 0x2A5A88, 0x1A3E64, 0xF4F9FF, 0xC2D4EC, 0xFFB703)
        case .ink:      return (0x12141C, 0x0A0C12, 0x2A3148, 0x1A2034, 0xF2F5FF, 0xB4C0DC, 0x7CFFCB)
        case .sand:     return (0x3A2E22, 0x241C14, 0x7A6248, 0x564432, 0xFFF9F2, 0xE6D2BC, 0x6EC8FF)
        case .violet:   return (0x1A1030, 0x100818, 0x4A2C88, 0x321C64, 0xF7F2FF, 0xD0C0EE, 0xFFD23F)
        case .copper:   return (0x32180C, 0x1E0E06, 0x8A4420, 0x642E14, 0xFFF6F0, 0xF0C8B0, 0x8EE4FF)
        case .custom:   return Self.customHex
        }
    }
    /// Dark shell around the colour chosen in the picker (`twinplay.menuCustomColor`).
    private static var customHex: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32) {
        let stored = UserDefaults.standard.integer(forKey: customColorKey)
        let base = stored == 0 ? 0x10566A : UInt32(stored & 0xFFFFFF)
        func mix(_ hex: UInt32, _ t: Double) -> UInt32 {
            let r = Double((hex >> 16) & 0xFF), g = Double((hex >> 8) & 0xFF), b = Double(hex & 0xFF)
            let c: (Double) -> UInt32 = { UInt32(min(255, max(0, $0 * t))) }
            return (c(r) << 16) | (c(g) << 8) | c(b)
        }
        return (mix(base, 0.45), mix(base, 0.22), base, mix(base, 0.72), 0xF4FBFF, 0xC5D7E4, 0xFFD23F)
    }
    var bodyTop: RGB { RGB(hex.0) }
    var bodyBottom: RGB { RGB(hex.1) }
    var screenTop: RGB { RGB(hex.2) }
    var screenBottom: RGB { RGB(hex.3) }
    var text: RGB { RGB(hex.4) }
    var dim: RGB { RGB(hex.5) }
    var accent: RGB { RGB(hex.6) }
}

struct ClassicScreenPanel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(ClassicPalette.screen))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.black.opacity(0.55), lineWidth: 3))
            .padding(6)
    }
}

struct ClassicHingeBand: View {
    var body: some View { Rectangle().fill(Color.black.opacity(0.6)) }
}

struct ClassicStatusBar: View {
    let menu: AnyView
    /// #3b: room kept free on the right for the Duo's system battery pill.
    var trailingClearance: CGFloat = 0
    @State private var battery: Float = UIDevice.current.batteryLevel
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi").font(.caption2)
            Image(systemName: batteryIcon).font(.caption2)
            Text("TwinPlay")
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(ClassicPalette.accent))
                .foregroundStyle(Color.black.opacity(0.8))
                .lineLimit(1).fixedSize()
            Spacer(minLength: 4)
            // Date/time never squeezed: when the top screen is narrow (landscape split, hinge band)
            // it drops to the time alone, then disappears, so the + and menu buttons always fit.
            TimelineView(.everyMinute) { ctx in
                ViewThatFits(in: .horizontal) {
                    (Text(ctx.date, format: .dateTime.month(.twoDigits).day(.twoDigits)).monospacedDigit()
                     + Text("  ") + Text(ctx.date, format: .dateTime.hour().minute()).monospacedDigit())
                        .lineLimit(1).fixedSize()
                    Text(ctx.date, format: .dateTime.hour().minute()).monospacedDigit().lineLimit(1).fixedSize()
                    Color.clear.frame(width: 0, height: 0)
                }
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            menu
        }
        .padding(.trailing, trailingClearance)
        .foregroundStyle(ClassicPalette.text)
        .onAppear { UIDevice.current.isBatteryMonitoringEnabled = true; battery = UIDevice.current.batteryLevel }
    }
    private var batteryIcon: String {
        guard battery >= 0 else { return "battery.100" }
        switch battery { case ..<0.15: return "battery.0"; case ..<0.4: return "battery.25"; case ..<0.65: return "battery.50"; case ..<0.9: return "battery.75"; default: return "battery.100" }
    }
}

struct ClassicGameCard: View {
    let entry: ROMLibrary.Entry
    static func subtitle(_ e: ROMLibrary.Entry) -> String {
        var parts = [e.system.longName]
        if let c = e.gameCode, !c.isEmpty { parts.append(c) }
        return parts.joined(separator: " · ")
    }
    var body: some View {
        GameInfoCard(entry: entry)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
    static func lastPlayed(_ d: Date?) -> String {
        guard let d else { return "Never".loc }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today".loc }
        if cal.isDateInYesterday(d) { return "Yesterday".loc }
        return d.formatted(.dateTime.month(.abbreviated).day())
    }
    static func duration(_ s: Double) -> String {
        let m = Int(s / 60)
        if m < 1 { return s > 0 ? "<1m" : "0m" }
        return m < 60 ? "\(m)m" : "\(m / 60)h \(m % 60)m"
    }
}

struct ClassicInitials: View {
    let name: String
    var body: some View {
        RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.12))
            .overlay(Text(String(name.prefix(2)).uppercased()).font(.system(.title, design: .rounded).weight(.heavy)).foregroundStyle(ClassicPalette.text))
    }
}

struct ClassicBubble: View {
    var compact = false
    let title: String, subtitle: String
    var body: some View {
        Group {
            if compact {
                // Short screens (landscape phone): one line, title + dimmed subtitle.
                HStack(spacing: 6) {
                    Text(title).font(.system(.subheadline, design: .rounded).weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.system(.caption2, design: .rounded)).foregroundStyle(ClassicPalette.dim).lineLimit(1)
                    }
                }
            } else {
                VStack(spacing: 2) {
                    Text(title).font(.system(.headline, design: .rounded)).lineLimit(1).minimumScaleFactor(0.7)
                    Text(subtitle).font(.system(.caption2, design: .rounded)).foregroundStyle(ClassicPalette.dim)
                }
            }
        }
        .foregroundStyle(ClassicPalette.text)
        .padding(.vertical, compact ? 4 : 8).padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .background(BubbleShape().fill(ClassicPalette.panel))
        .overlay(BubbleShape().stroke(ClassicPalette.line, lineWidth: 1.5))
        .padding(.bottom, compact ? 6 : 8)
    }
}

/// Rounded label with a small tail pointing down at the selected icon.
struct BubbleShape: Shape {
    func path(in r: CGRect) -> Path {
        let tail: CGFloat = 8, body = CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height)
        var p = Path(roundedRect: body, cornerRadius: 12, style: .continuous)
        p.move(to: CGPoint(x: r.midX - tail, y: r.maxY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY + tail))
        p.addLine(to: CGPoint(x: r.midX + tail, y: r.maxY))
        return p
    }
}

struct ClassicIconTile: View {
    let entry: ROMLibrary.Entry
    let selected: Bool
    let size: CGFloat
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(selected ? ClassicPalette.accent : Color.white.opacity(0.92))
                icon.padding(size * 0.14)
                if entry.favorite {
                    Image(systemName: "star.fill").font(.system(size: size * 0.16))
                        .foregroundStyle(.yellow).shadow(radius: 1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(size * 0.06)
                }
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(selected ? 0.45 : 0.25), radius: selected ? 6 : 2, y: 2)
            if selected {
                Text("START")
                    .font(.system(size: max(9, size * 0.13), weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.8))
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(Capsule().fill(ClassicPalette.accent))
                    .offset(y: -size * 0.08)
            }
        }
        .animation(.spring(response: 0.3), value: selected)
    }
    @ViewBuilder private var icon: some View {
        if let i = entry.icon {
            Image(uiImage: i).resizable().interpolation(.none).scaledToFit()
        } else if let c = entry.cover ?? entry.titleScreen {
            Image(uiImage: c).resizable().scaledToFill().clipShape(RoundedRectangle(cornerRadius: size * 0.12))
        } else {
            Text(String(entry.name.prefix(2)).uppercased())
                .font(.system(size: size * 0.3, weight: .heavy, design: .rounded)).foregroundStyle(Color.black.opacity(0.7))
        }
    }
}

struct ClassicScrollBar: View {
    let index: Int, count: Int
    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { g in
                let frac = count > 1 ? CGFloat(index) / CGFloat(count - 1) : 0
                let thumb = max(18, g.size.width / CGFloat(max(count, 1)))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.35))
                    Capsule().fill(ClassicPalette.accent).frame(width: thumb).offset(x: (g.size.width - thumb) * frac)
                }
            }
            .frame(height: 6)
            Text(count == 0 ? "0/0" : "\(index + 1)/\(count)")
                .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(ClassicPalette.dim)
        }
    }
}

struct ClassicPillButton: View {
    let glyph: String, label: String
    var star = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(glyph).font(.system(size: 10, weight: .heavy, design: .rounded))
                    .frame(width: 18, height: 18).background(Circle().fill(Color.white.opacity(0.85))).foregroundStyle(Color.black.opacity(0.8))
                if star { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow) }
                Text(label.loc).font(.system(.subheadline, design: .rounded).weight(.semibold))
            }
            .foregroundStyle(ClassicPalette.text)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .glassSurface(Capsule(), interactive: true)
            .overlay(Capsule().strokeBorder(ClassicPalette.line))
        }
        .buttonStyle(.plain)
    }
}
