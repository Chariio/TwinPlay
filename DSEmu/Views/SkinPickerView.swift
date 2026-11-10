// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Skin picker with a live preview. Original designs only (no logos or trade dress).
import SwiftUI

/// Small drawing of a handheld in a skin: shell with the lid finish, screen bezel(s), D-pad and buttons.
struct SkinPreview: View {
    let skin: Skin
    var system: GameSystem = .ds
    var screen: UIImage? = nil

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let p = skin.palette
            let shape = RoundedRectangle(cornerRadius: w * 0.09, style: .continuous)
            ZStack {
                if p.drawsShell {
                    if skin.lid.translucent {
                        shape.fill(p.background)
                    }
                    shape.fill(LinearGradient(colors: [p.shellTop, p.shellBottom], startPoint: .top, endPoint: .bottom))
                    shape.fill(LinearGradient(stops: [.init(color: .white.opacity(0), location: 0),
                                                      .init(color: .white.opacity(0.35 * skin.lid.gloss), location: 0.4),
                                                      .init(color: .white.opacity(0), location: 0.62)],
                                              startPoint: .topLeading, endPoint: .bottomTrailing)).blendMode(.screen)
                    shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.5), skin.lid.edge],
                                                      startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5)
                } else {
                    shape.fill(Color.black)
                    shape.strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                }
                let single = system.isSingleScreen
                let sw = w * 0.74
                let sh = single ? sw / system.screenAspect : sw * 0.75
                VStack(spacing: h * 0.03) {
                    screenBox(width: sw, height: min(sh, h * (single ? 0.42 : 0.3)), p)
                    if !single { screenBox(width: sw, height: min(sh, h * 0.3), p) }
                    HStack {
                        if system == .n64 {
                            analogStick(size: w * 0.22, p)
                        } else {
                            dpad(size: w * 0.24, p)
                        }
                        Spacer()
                        if system == .n64 {
                            n64Buttons(size: w * 0.28, p)
                        } else {
                            ZStack {
                                Circle().fill(p.buttonFill).overlay(Circle().stroke(p.buttonStroke, lineWidth: 1))
                                    .frame(width: w * 0.11).offset(x: w * 0.06, y: -w * 0.04)
                                Circle().fill(p.buttonFill).overlay(Circle().stroke(p.buttonStroke, lineWidth: 1))
                                    .frame(width: w * 0.11).offset(x: -w * 0.06, y: w * 0.04)
                            }
                            .frame(width: w * 0.26, height: w * 0.24)
                        }
                    }
                    .padding(.horizontal, w * 0.08)
                }
                .padding(.vertical, h * 0.05)
            }
        }
    }

    private func screenBox(width: CGFloat, height: CGFloat, _ p: SkinPalette) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(p.bezel)
            Group {
                if let screen { Image(uiImage: screen).resizable().interpolation(.none) }
                else { LinearGradient(colors: [Color(red: 0.45, green: 0.75, blue: 0.98), Color(red: 0.35, green: 0.72, blue: 0.40)],
                                      startPoint: .top, endPoint: .bottom) }
            }
            .padding(3)
        }
        .frame(width: width, height: height)
    }

    private func dpad(size s: CGFloat, _ p: SkinPalette) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: s * 0.08).fill(p.dpadFill).frame(width: s, height: s * 0.34)
            RoundedRectangle(cornerRadius: s * 0.08).fill(p.dpadFill).frame(width: s * 0.34, height: s)
        }
        .frame(width: s, height: s)
    }

    private func analogStick(size s: CGFloat, _ p: SkinPalette) -> some View {
        ZStack {
            Circle().fill(p.dpadFill.opacity(0.85))
            Circle().stroke(p.shellEdge, lineWidth: 1)
            Circle().fill(p.dpadFill)
                .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
                .frame(width: s * 0.55, height: s * 0.55)
        }
        .frame(width: s, height: s)
    }

    private func n64Buttons(size s: CGFloat, _ p: SkinPalette) -> some View {
        let a = p.faceColors["A"] ?? p.buttonFill
        let b = p.faceColors["B"] ?? p.buttonFill
        let c = p.faceColors["C"] ?? Color(red: 0.86, green: 0.72, blue: 0.18)
        return ZStack {
            Circle().fill(a).overlay(Circle().stroke(p.buttonStroke, lineWidth: 0.8))
                .frame(width: s * 0.36).offset(x: s * 0.22, y: s * 0.02)
            Circle().fill(b).overlay(Circle().stroke(p.buttonStroke, lineWidth: 0.8))
                .frame(width: s * 0.28).offset(x: -s * 0.16, y: s * 0.16)
            // C buttons as a small yellow diamond cluster
            ForEach(Array([CGSize(width: 0, height: -0.18), CGSize(width: 0.16, height: 0),
                            CGSize(width: 0, height: 0.18), CGSize(width: -0.16, height: 0)].enumerated()), id: \.offset) { _, o in
                Circle().fill(c).frame(width: s * 0.16)
                    .offset(x: s * o.width, y: s * o.height - s * 0.16)
            }
        }
        .frame(width: s, height: s)
    }
}

/// Lists every skin, with a large live preview of the selected one. Premium skins keep their Plus lock.
/// Game Boy and Game Boy Color share the GBA catalogue. NES and Super NES have their own.
struct SkinPickerView: View {
    /// Which tab opens first (the running game's system when opened from the game menu).
    var initialSystem: GameSystem = .ds
    /// The running game's picture, shown inside the preview.
    var screen: UIImage? = nil
    @Environment(\.dismiss) private var dismiss
    @AppStorage("skin") private var skinRaw = Skin.classicGray.rawValue
    @AppStorage("skinGBA") private var skinGBARaw = Skin.gbaIndigo.rawValue
    @AppStorage("skinNES") private var skinNESRaw = Skin.nesFog.rawValue
    @AppStorage("skinSNES") private var skinSNESRaw = Skin.snesFog.rawValue
    @AppStorage("skinN64") private var skinN64Raw = Skin.n64Original.rawValue
    @AppStorage("skinN3DS") private var skinN3DSRaw = Skin.n3dsPearl.rawValue
    @ObservedObject private var store = Store.shared
    @State private var tab: GameSystem = .ds
    @State private var preview: Skin?

    private static let tabs: [GameSystem] = [.ds, .gba, .nes, .snes, .n64, .n3ds]

    private var storedRaw: String {
        switch tab {
        case .ds: return skinRaw
        case .nes: return skinNESRaw
        case .snes: return skinSNESRaw
        case .n64: return skinN64Raw
        case .n3ds: return skinN3DSRaw
        default: return skinGBARaw
        }
    }
    private var current: Skin { Skin.current(for: tab, raw: storedRaw) }
    private var previewSystem: GameSystem {
        if tab == .gba && initialSystem.isGameBoy { return initialSystem }
        return tab
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Picker("System", selection: $tab) {
                        Text("DS").tag(GameSystem.ds)
                        Text("GBA").tag(GameSystem.gba)
                        Text("NES").tag(GameSystem.nes)
                        Text("SNES").tag(GameSystem.snes)
                        Text("N64").tag(GameSystem.n64)
                        Text("3DS").tag(GameSystem.n3ds)
                    }
                    .pickerStyle(.segmented)

                    let shown = preview ?? current
                    SkinPreview(skin: shown, system: previewSystem, screen: screen)
                        .frame(width: 180, height: tab.isSingleScreen ? 250 : 300)
                        .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
                        .animation(.easeInOut(duration: 0.2), value: shown)
                    Text(shown.label).font(.headline)
                    if !shown.isFree && !Store.allows(.extraSkins) {
                        Label("Included with TwinPlay Plus", systemImage: "lock.fill").font(.footnote).foregroundStyle(.secondary)
                    }

                    // #22: the Heritage pack (classic-handheld look, free) first, then the other skins.
                    ForEach(Self.groups(for: tab), id: \.title) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.title.loc).font(.subheadline.weight(.semibold))
                            if let note = group.note { Text(note.loc).font(.caption).foregroundStyle(.secondary) }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 14)], spacing: 16) {
                                ForEach(group.skins) { s in
                                    Button { choose(s) } label: { tile(s) }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel(s.label + (s == current ? ", selected".loc : "") + (locked(s) ? ", locked".loc : ""))
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("The skin colours the whole play area (shell, screen surround and controls) and the lid. DS, NES, Super NES, N64 and 3DS each have their own. Game Boy and Game Boy Color share the GBA skin.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding()
            }
            .navigationTitle("Skins")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear {
                switch initialSystem {
                case .ds: tab = .ds
                case .nes: tab = .nes
                case .snes: tab = .snes
                case .n64: tab = .n64
                case .n3ds: tab = .n3ds
                default: tab = .gba
                }
                #if DEBUG
                // Screenshot aid: -TwinPlaySkinTab n64|n3ds|nes|snes|gba|ds
                if let raw = UserDefaults.standard.string(forKey: "TwinPlaySkinTab") {
                    switch raw.lowercased() {
                    case "n64": tab = .n64
                    case "n3ds", "3ds": tab = .n3ds
                    case "nes": tab = .nes
                    case "snes": tab = .snes
                    case "gba", "gb", "gbc": tab = .gba
                    case "ds": tab = .ds
                    default: break
                    }
                }
                #endif
            }
            .onChange(of: tab) { _ in preview = nil }
            .padScope("skins") { e in
                let list = Self.groups(for: tab).flatMap(\.skins)
                let i = list.firstIndex(of: preview ?? current) ?? 0
                switch e {
                case .left, .up: preview = list[(i + list.count - 1) % list.count]
                case .right, .down: preview = list[(i + 1) % list.count]
                case .a: choose(preview ?? current)
                case .l, .r:
                    let tabs = Self.tabs
                    let i = tabs.firstIndex(of: tab) ?? 0
                    tab = tabs[(i + (e == .r ? 1 : tabs.count - 1)) % tabs.count]
                case .b, .menu: dismiss()
                default: break
                }
            }
        }
    }

    struct SkinGroup { let title: String; let note: String?; let skins: [Skin] }

    /// Picker sections: the clear-plastic rainbow first (so it is easy to find), then
    /// Heritage, then every other skin. Retired opaque DS colours are already omitted
    /// by `Skin.skins(for:)`.
    static func groups(for system: GameSystem) -> [SkinGroup] {
        let all = Skin.skins(for: system)
        let clear = ClearHue.pickerOrder.compactMap { hue in all.first { $0.clearHue == hue } }
        let heritage = all.filter(\.isHeritage)
        let other = all.filter { !$0.isHeritage && !$0.isClearRainbow }
        return [SkinGroup(title: "Clear · Translucent", note: "Vivid see-through plastic. Free.", skins: clear),
                SkinGroup(title: "Heritage", note: "Classic handheld shapes and colours. Free.", skins: heritage),
                SkinGroup(title: "More skins", note: nil, skins: other)].filter { !$0.skins.isEmpty }
    }

    private func locked(_ s: Skin) -> Bool { !s.isFree && !Store.allows(.extraSkins) }

    private func choose(_ s: Skin) {
        preview = s
        guard s.isFree || Store.gate(.extraSkins) else { return }
        switch tab {
        case .ds: skinRaw = s.rawValue
        case .nes: skinNESRaw = s.rawValue
        case .snes: skinSNESRaw = s.rawValue
        case .n64: skinN64Raw = s.rawValue
        case .n3ds: skinN3DSRaw = s.rawValue
        default: skinGBARaw = s.rawValue
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func tile(_ s: Skin) -> some View {
        VStack(spacing: 6) {
            SkinPreview(skin: s, system: previewSystem)
                .frame(width: 64, height: tab.isSingleScreen ? 88 : 104)
                .overlay(alignment: .topTrailing) {
                    if locked(s) {
                        Image(systemName: "lock.fill").font(.caption2.weight(.bold)).foregroundStyle(.white)
                            .padding(4).background(Circle().fill(.black.opacity(0.6))).offset(x: 6, y: -6)
                    }
                }
            Text(s.isHeritage ? s.label.replacingOccurrences(of: "Heritage ", with: "") : s.label).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(s == current ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(s == current ? Color.accentColor : .clear, lineWidth: 2))
    }
}
