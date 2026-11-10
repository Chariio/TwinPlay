// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Arrangeable icon grid for the Classic DS Menu's bottom screen: pages of slots that hold a game,
// a folder of games or nothing (empty slot). Long-press to edit, drag icons anywhere, saved per folder.
// Original TwinPlay styling; no third-party artwork.
import SwiftUI

/// One place in the grid.
struct ClassicSlot: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case game, empty, folder }
    var id: String = UUID().uuidString
    var kind: Kind
    var game: String? = nil          // ROM file name (url.lastPathComponent)
    var name: String? = nil          // folder name
    var items: [String]? = nil       // folder contents (ROM file names, in order)

    static func game(_ f: String) -> ClassicSlot { ClassicSlot(id: "g-" + f, kind: .game, game: f) }
    static func empty() -> ClassicSlot { ClassicSlot(kind: .empty) }
}

/// Saved arrangements, one per Classic folder (All, DS, GBA, ...). Stored in UserDefaults as JSON.
final class ClassicGridStore {
    static let shared = ClassicGridStore()
    private let key = "classicGridLayouts"
    private(set) var layouts: [String: [ClassicSlot]] = [:]

    init() {
        if let d = UserDefaults.standard.data(forKey: key), let l = try? JSONDecoder().decode([String: [ClassicSlot]].self, from: d) { layouts = l }
    }
    func save(_ slots: [ClassicSlot], for k: String) {
        layouts[k] = slots
        if let d = try? JSONEncoder().encode(layouts) { UserDefaults.standard.set(d, forKey: key) }
    }

    /// The saved arrangement brought up to date with the games that exist now: removed games
    /// disappear, new games are added at the end, empty slots and folders are kept.
    static func reconcile(_ saved: [ClassicSlot]?, games: [String]) -> [ClassicSlot] {
        let present = Set(games)
        var used = Set<String>()
        var out: [ClassicSlot] = []
        for var s in saved ?? [] {
            switch s.kind {
            case .game:
                guard let g = s.game, present.contains(g), !used.contains(g) else { continue }
                used.insert(g); out.append(s)
            case .folder:
                s.items = (s.items ?? []).filter { present.contains($0) && !used.contains($0) }
                s.items?.forEach { used.insert($0) }
                out.append(s)
            case .empty:
                out.append(s)
            }
        }
        for g in games where !used.contains(g) { out.append(.game(g)) }
        while out.last?.kind == .empty { out.removeLast() }   // trailing gaps carry no meaning
        return out
    }
}

/// State and logic of the grid (also driven by the controller through ClassicDSMenuView).
final class ClassicGridModel: ObservableObject {
    @Published var slots: [ClassicSlot] = []
    @Published var selected = 0
    @Published var page = 0
    @Published var editing = false
    @Published var openFolder: String?            // slot id of the open folder
    @Published var carried: String?               // slot id picked up with the controller
    @Published var renaming: String?              // folder slot id being renamed
    @Published var perPage = 12
    var columns = 4
    private var key = "all"
    private var carryBackup: [ClassicSlot]?
    private var entriesByFile: [String: ROMLibrary.Entry] = [:]

    func load(key: String, entries: [ROMLibrary.Entry]) {
        let files = entries.map(\.url.lastPathComponent)
        entriesByFile = Dictionary(entries.map { ($0.url.lastPathComponent, $0) }, uniquingKeysWith: { a, _ in a })
        let fresh = ClassicGridStore.reconcile(ClassicGridStore.shared.layouts[key], games: files)
        if key != self.key { selected = 0; page = 0; openFolder = nil; editing = false }
        self.key = key
        if fresh != slots { slots = fresh }
        if fresh != ClassicGridStore.shared.layouts[key] { ClassicGridStore.shared.save(fresh, for: key) }
        clampSelection()
    }
    private func persist() { ClassicGridStore.shared.save(slots, for: key) }

    func entry(_ file: String?) -> ROMLibrary.Entry? { file.flatMap { entriesByFile[$0] } }

    /// Slots on screen: the top level, or the games inside the open folder.
    var visible: [ClassicSlot] {
        guard let f = openFolder, let folder = slots.first(where: { $0.id == f }) else { return slots }
        return (folder.items ?? []).map { .game($0) }
    }
    var folderTitle: String? { openFolder.flatMap { id in slots.first { $0.id == id }?.name } }
    var selectedSlot: ClassicSlot? { visible.indices.contains(selected) ? visible[selected] : nil }
    var selectedEntry: ROMLibrary.Entry? { selectedSlot?.kind == .game ? entry(selectedSlot?.game) : nil }
    var pageCount: Int { max(1, (visible.count + perPage - 1) / perPage + (editing && openFolder == nil ? 1 : 0)) }

    func clampSelection() {
        let n = visible.count
        if selected >= n { selected = max(0, n - 1) }
        page = min(max(0, selected / max(perPage, 1)), pageCount - 1)
    }

    func select(_ i: Int) {
        let n = max(visible.count, 1)
        let maxIndex = editing && openFolder == nil ? pageCount * perPage - 1 : n - 1
        let v = min(max(i, 0), maxIndex)
        guard v != selected || carried != nil else { return }
        if let c = carried { moveSlot(id: c, to: v) }
        selected = v
        page = v / max(perPage, 1)
        UISelectionFeedbackGenerator().selectionChanged()
    }

    // MARK: Editing

    /// Puts slot `id` at index `to`; whatever was there takes its old place (a swap), so dropping on
    /// an empty slot leaves a gap behind, exactly like moving an icon on a handheld home screen.
    func moveSlot(id: String, to: Int) {
        if let f = openFolder { moveInFolder(f, id: id, to: to); return }
        guard let from = slots.firstIndex(where: { $0.id == id }), to >= 0 else { return }
        while slots.count <= to { slots.append(.empty()) }
        slots.swapAt(from, to)
        while slots.last?.kind == .empty && slots.count - 1 > max(to, from) { slots.removeLast() }
        persist()
    }
    private func moveInFolder(_ f: String, id: String, to: Int) {
        guard let fi = slots.firstIndex(where: { $0.id == f }), var items = slots[fi].items,
              let from = items.firstIndex(where: { "g-" + $0 == id }) else { return }
        let t = min(max(to, 0), items.count - 1)
        items.swapAt(from, t)
        slots[fi].items = items
        persist()
    }
    /// Drops a game onto a folder (top level only).
    func put(id: String, intoFolder folderIndex: Int) -> Bool {
        guard openFolder == nil, slots.indices.contains(folderIndex), slots[folderIndex].kind == .folder,
              let gi = slots.firstIndex(where: { $0.id == id }), slots[gi].kind == .game, let g = slots[gi].game else { return false }
        slots[folderIndex].items = (slots[folderIndex].items ?? []) + [g]
        slots[gi] = .empty()
        while slots.last?.kind == .empty { slots.removeLast() }
        persist()
        return true
    }
    func addFolder() {
        let n = slots.filter { $0.kind == .folder }.count + 1
        var f = ClassicSlot(kind: .folder, name: String(localized: "Folder \(n)"), items: [])
        // If a game is selected, it becomes the folder's first item.
        if let s = selectedSlot, s.kind == .game, let g = s.game, openFolder == nil, slots.indices.contains(selected) {
            f.items = [g]; slots[selected] = f
        } else {
            slots.insert(f, at: min(selected, slots.count))
        }
        persist()
    }
    func addEmpty() {
        guard openFolder == nil else { return }
        slots.insert(.empty(), at: min(selected, slots.count))
        persist()
    }
    func removeSelectedEmptyOrFolder() {
        guard openFolder == nil, slots.indices.contains(selected) else { return }
        let s = slots[selected]
        if s.kind == .empty { slots.remove(at: selected) }
        else if s.kind == .folder { slots.replaceSubrange(selected...selected, with: (s.items ?? []).map { ClassicSlot.game($0) }) }
        persist(); clampSelection()
    }
    func takeOutOfFolder() {
        guard let f = openFolder, let fi = slots.firstIndex(where: { $0.id == f }), let s = selectedSlot, let g = s.game else { return }
        slots[fi].items?.removeAll { $0 == g }
        slots.insert(.game(g), at: fi + 1)
        persist(); clampSelection()
    }
    func rename(_ id: String, to name: String) {
        guard let i = slots.firstIndex(where: { $0.id == id }) else { return }
        let t = name.trimmingCharacters(in: .whitespaces)
        slots[i].name = t.isEmpty ? slots[i].name : String(t.prefix(24)); persist()
    }

    /// Controller pick-up: A lifts the selected icon, the D-pad carries it, A drops, B puts it back.
    func toggleCarry() {
        if carried != nil { carried = nil; carryBackup = nil; persist(); UIImpactFeedbackGenerator(style: .medium).impactOccurred(); return }
        guard let s = selectedSlot else { return }
        carryBackup = slots; carried = s.id
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
    func cancelCarry() {
        if let b = carryBackup { slots = b; persist() }
        carried = nil; carryBackup = nil; clampSelection()
    }
    func cancelCarryIfNeeded() { if carried != nil { carried = nil; carryBackup = nil; persist() } }
    func openSelectedFolder() {
        guard let s = selectedSlot, s.kind == .folder else { return }
        openFolder = s.id; selected = 0; page = 0
    }
    func closeFolder() {
        guard let f = openFolder else { return }
        openFolder = nil
        selected = slots.firstIndex { $0.id == f } ?? 0
        clampSelection()
    }
}

/// The grid itself.
struct ClassicGridView: View {
    @ObservedObject var model: ClassicGridModel
    let columns: Int
    let onPlay: (ROMLibrary.Entry) -> Void
    @State private var drag: (id: String, point: CGPoint)?
    @State private var wiggle = false
    @State private var lastFlip = Date.distantPast
    @State private var renameText = ""

    var body: some View {
        GeometryReader { g in
            // Columns share the width; on a short screen (landscape phone) the icons shrink to the
            // height so at least one full row always fits above the page dots.
            let colW = g.size.width / CGFloat(columns)
            let cell = max(20, min(colW, g.size.height - 14))
            let rows = max(1, Int((g.size.height - 14) / cell))
            let perPage = rows * columns
            let slots = model.visible
            VStack(spacing: 4) {
                ZStack(alignment: .topLeading) {
                    ForEach(0..<model.pageCount, id: \.self) { p in
                        ForEach(0..<perPage, id: \.self) { k in
                            let i = p * perPage + k
                            let x = CGFloat(p) * g.size.width + (CGFloat(k % columns) + 0.5) * colW
                            let y = (CGFloat(k / columns) + 0.5) * cell
                            cellView(i: i, slot: slots.indices.contains(i) ? slots[i] : nil, cell: cell, perPage: perPage, width: g.size.width)
                                .position(x: x, y: y)
                        }
                    }
                    if let d = drag, let s = slots.first(where: { $0.id == d.id }) {
                        slotIcon(s, size: cell * 0.86, selected: true)
                            .scaleEffect(1.15).shadow(radius: 10)
                            .position(x: d.point.x + CGFloat(model.page) * g.size.width, y: d.point.y)
                            .allowsHitTesting(false)
                    }
                }
                .offset(x: -CGFloat(model.page) * g.size.width)
                .frame(width: g.size.width, height: CGFloat(rows) * cell, alignment: .topLeading)
                .clipped()
                .contentShape(Rectangle())
                .coordinateSpace(name: "classicGrid")
                .animation(.spring(response: 0.35), value: model.page)
                .animation(.spring(response: 0.3), value: model.slots)
                .gesture(model.editing ? nil : DragGesture(minimumDistance: 25).onEnded { v in
                    if v.translation.width < -40 { model.page = min(model.page + 1, model.pageCount - 1) }
                    if v.translation.width > 40 { model.page = max(model.page - 1, 0) }
                })
                HStack(spacing: 6) {
                    ForEach(0..<model.pageCount, id: \.self) { p in
                        Circle().fill(p == model.page ? ClassicPalette.accent : ClassicPalette.line).frame(width: 6, height: 6)
                    }
                }
                .frame(height: 10)
            }
            .onAppear { apply(perPage) }
            .onChange(of: perPage) { n in apply(n) }
        }
        .onChange(of: model.editing) { e in wiggle = e }
        .onAppear { wiggle = model.editing }
        .alert("Folder name", isPresented: Binding(get: { model.renaming != nil }, set: { if !$0 { model.renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") { if let id = model.renaming { model.rename(id, to: renameText) }; model.renaming = nil }
            Button("Cancel", role: .cancel) { model.renaming = nil }
        }
        .onChange(of: model.renaming) { id in renameText = id.flatMap { i in model.slots.first { $0.id == i }?.name } ?? "" }
    }

    private func apply(_ n: Int) {
        DispatchQueue.main.async {
            if model.perPage != n { model.perPage = n }
            model.columns = columns
            model.clampSelection()
        }
    }

    @ViewBuilder
    private func cellView(i: Int, slot: ClassicSlot?, cell: CGFloat, perPage: Int, width: CGFloat) -> some View {
        let isSel = i == model.selected
        let size = cell * 0.8
        let lifted = slot != nil && (model.carried == slot?.id || drag?.id == slot?.id)
        ZStack {
            if let s = slot, s.kind != .empty {
                slotIcon(s, size: size, selected: isSel)
                    .opacity(drag?.id == s.id ? 0.25 : 1)
                    .scaleEffect(model.carried == s.id ? 1.15 : 1)
                    .rotationEffect(.degrees(model.editing && !lifted ? (wiggle ? 2.2 : -2.2) * (i % 2 == 0 ? 1 : -1) : 0))
                    .animation(model.editing ? .easeInOut(duration: 0.14).repeatForever(autoreverses: true) : .default, value: wiggle)
            } else if model.editing {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .strokeBorder(ClassicPalette.line, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .frame(width: size, height: size)
            }
            if isSel {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .strokeBorder(ClassicPalette.accent, lineWidth: 3)
                    .frame(width: size + 8, height: size + 8)
            }
        }
        .frame(width: cell, height: cell)
        .contentShape(Rectangle())
        .onTapGesture { tap(i, slot) }
        .onLongPressGesture(minimumDuration: 0.45) {
            if !model.editing { model.editing = true; model.selected = i; UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
        }
        .simultaneousGesture(model.editing && slot != nil && slot?.kind != .empty ? dragGesture(slot!, cell: cell, perPage: perPage, width: width) : nil)
        .accessibilityLabel(label(slot))
    }

    private func label(_ s: ClassicSlot?) -> String {
        guard let s else { return "Empty slot".loc }
        switch s.kind {
        case .game: return model.entry(s.game)?.name ?? "Game".loc
        case .folder: return String(localized: "Folder \(s.name ?? ""), \(s.items?.count ?? 0) games")
        case .empty: return "Empty slot".loc
        }
    }

    private func tap(_ i: Int, _ slot: ClassicSlot?) {
        if model.editing { model.select(i); return }
        guard let s = slot else { return }
        if i == model.selected {
            if s.kind == .folder { model.openSelectedFolder() }
            else if s.kind == .game, let e = model.entry(s.game) { onPlay(e) }
        } else { withAnimation(.spring(response: 0.25)) { model.select(i) } }
    }

    private func dragGesture(_ s: ClassicSlot, cell: CGFloat, perPage: Int, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("classicGrid"))
            .onChanged { v in
                drag = (s.id, v.location)
                // Hold an icon at the left/right edge to carry it to the neighbouring page.
                if Date().timeIntervalSince(lastFlip) > 0.8 {
                    if v.location.x > width - 18 && model.page < model.pageCount - 1 { model.page += 1; lastFlip = Date() }
                    else if v.location.x < 18 && model.page > 0 { model.page -= 1; lastFlip = Date() }
                }
            }
            .onEnded { v in
                defer { drag = nil }
                let col = min(max(Int(v.location.x / (width / CGFloat(columns))), 0), columns - 1)
                let row = max(Int(v.location.y / cell), 0)
                let target = model.page * perPage + min(row, perPage / columns - 1) * columns + col
                let vis = model.visible
                if vis.indices.contains(target), vis[target].kind == .folder, s.kind == .game, vis[target].id != s.id,
                   model.put(id: s.id, intoFolder: target) {
                    model.selected = target
                } else {
                    model.moveSlot(id: s.id, to: target)
                    model.selected = target
                }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
    }

    @ViewBuilder
    private func slotIcon(_ s: ClassicSlot, size: CGFloat, selected: Bool) -> some View {
        switch s.kind {
        case .game:
            if let e = model.entry(s.game) { ClassicIconTile(entry: e, selected: false, size: size) }
        case .folder:
            ClassicFolderTile(name: s.name ?? "Folder", entries: (s.items ?? []).prefix(4).compactMap { model.entry($0) }, size: size)
        case .empty:
            EmptyView()
        }
    }
}

/// Folder icon: a translucent rounded tile with up to four mini icons and its name.
struct ClassicFolderTile: View {
    let name: String
    let entries: [ROMLibrary.Entry]
    let size: CGFloat
    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(LinearGradient(colors: [Color.white.opacity(0.35), Color.white.opacity(0.18)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).strokeBorder(Color.white.opacity(0.5), lineWidth: 1.5))
            let m = size * 0.36
            LazyVGrid(columns: [GridItem(.fixed(m), spacing: size * 0.06), GridItem(.fixed(m), spacing: size * 0.06)], spacing: size * 0.06) {
                ForEach(entries, id: \.id) { e in ClassicIconTile(entry: e, selected: false, size: m) }
            }
            .frame(width: size, height: size * 0.8, alignment: .center)
            .padding(.bottom, size * 0.18)
            Text(name).font(.system(size: max(8, size * 0.13), weight: .bold, design: .rounded))
                .foregroundStyle(ClassicPalette.text).lineLimit(1).padding(.horizontal, 4).padding(.bottom, size * 0.03)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.25), radius: 2, y: 2)
    }
}
